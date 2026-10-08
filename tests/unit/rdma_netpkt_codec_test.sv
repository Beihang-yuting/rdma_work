// 目录：单元测试层 tests/unit/rdma_netpkt_codec_test.sv。
// 职责：验证 rdma_netpkt_codec（外部 net_packet 的 RoCEv2 帧编解码）：RC SEND 往返、WRITE 的 RETH、
//   CMP_SWAP/FETCH_ADD 的 AtomicETH、URC opcode、UD 的 DETH，以及 ICRC 损坏的帧被拒。
// 依赖：rdma_netpkt_pkg 及外部 net_packet packet 类。
// 所有权与生命周期：测试只拥有本地 codec 与 packet 快照。
class rdma_netpkt_codec_test extends uvm_test;
  `uvm_component_utils(rdma_netpkt_codec_test)

  // 功能：构造测试组件。
  // 输入/输出及副作用：name/parent 建立 UVM 层级；尚未创建 codec 或 packet，测试对象只在 run_phase 持有。
  // 失败/边界：parent=null 是顶层 test 的正常形式；外部 net_packet 类型/字段不匹配在编译或用例中暴露。
  function new(string name = "rdma_netpkt_codec_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：创建带固定 payload 和 QP/PSN 的 RDMA 语义报文，作为编码输入快照。
  // 输入/输出及副作用：transport、opcode、name（输入）；返回本地 rdma_packet，不拥有 host-mem/队列资源。
  // 失败/边界：payload 为空仍是合法零长度 SEND；未知 transport/opcode 由 codec 返回明确错误。
  function automatic rdma_packet make_rdma_packet(
    string name,
    rdma_transport_e transport,
    rdma_network_opcode_e opcode
  );
    rdma_packet packet_value;

    packet_value = rdma_packet::type_id::create(name);
    packet_value.transport = transport;
    packet_value.opcode = opcode;
    packet_value.destination_qpn = 24'h12345;
    packet_value.source_qpn = 24'h45678;
    packet_value.psn = 24'h000011;
    packet_value.payload = '{8'hde, 8'had, 8'hbe, 8'hef,
                             8'h01, 8'h02, 8'h03, 8'h04};
    return packet_value;
  endfunction

  // 功能：比较两个 byte queue 是否逐字节相等，确认解码负载与源一致。
  // 输入/输出及副作用：lhs、rhs（输入）；只读比较并返回 bit，不修改任何 packet。
  // 失败/边界：长度不同立即返回 0；空 queue 只有在两者同时为空时相等。
  function automatic bit bytes_equal(
    byte unsigned lhs[$],
    byte unsigned rhs[$]
  );
    if (lhs.size() != rhs.size())
      return 1'b0;
    foreach (lhs[i]) begin
      if (lhs[i] != rhs[i])
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：检查状态码并在测试日志中保留编解码失败原因。
  // 输入/输出及副作用：tag、status、expected（输入）；失败通过 UVM error 报告，不推进任何生产游标。
  // 失败/边界：status 为空时报告独立错误并结束本次检查，避免解引用空句柄。
  function automatic void expect_status(
    string tag,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null) begin
      `uvm_error(tag, "codec returned null status")
      return;
    end
    if (status.code != expected)
      `uvm_error(tag, $sformatf("expected %s, got %s: %s",
                               expected.name(), status.code.name(),
                               status.message))
  endfunction

  // 功能：验证 RC SEND 生成 RoCEv2 BTH、调用 net_packet do_pack 并可由 parser 解回语义字段。
  // 输入/输出及副作用：codec、frame_bytes（局部输出）；只更新测试快照，不修改队列 PI/CI。
  // 失败/边界：缺少外层 Ethernet/IP/UDP/RoCE layer、QPN/PSN 或 payload 不一致均报告错误。
  task automatic test_rc_send_round_trip(
    rdma_netpkt_codec codec
  );
    rdma_packet source;
    rdma_packet decoded;
    byte unsigned frame_bytes[$];
    rdma_status status;

    source = make_rdma_packet("rc_send", RDMA_TRANSPORT_RC, RDMA_NET_SEND);
    status = codec.encode(source, frame_bytes);
    expect_status("RC_SEND_ENCODE", status, RDMA_SC_OK);
    if (frame_bytes.size() < 64)
      `uvm_error("RC_SEND_FRAME", $sformatf("frame too short: %0d", frame_bytes.size()))
    status = codec.decode(frame_bytes, decoded);
    expect_status("RC_SEND_DECODE", status, RDMA_SC_OK);
    if (decoded == null || decoded.transport != RDMA_TRANSPORT_RC ||
        decoded.opcode != RDMA_NET_SEND ||
        decoded.destination_qpn != source.destination_qpn ||
        decoded.psn != source.psn ||
        !bytes_equal(decoded.payload, source.payload))
      `uvm_error("RC_SEND_FIELDS", "RC SEND semantic round-trip mismatch")
  endtask

  // 功能：验证 RC WRITE 生成 RETH，并将 payload 长度投影到 RETH DMA length。
  // 输入/输出及副作用：codec（输入）；仅生成和解析值快照，不改变 host-mem 映射。
  // 失败/边界：RoCEv2 layer 缺失、RETH 长度错误或解析 opcode 不一致时报告错误。
  task automatic test_rc_write_reth(
    rdma_netpkt_codec codec
  );
    rdma_packet source;
    packet wire_packet;
    byte unsigned frame_bytes[$];
    rdma_status status;
    rocev2_bth roce;

    source = make_rdma_packet("rc_write", RDMA_TRANSPORT_RC,
                              RDMA_NET_RDMA_WRITE);
    status = codec.encode(source, frame_bytes);
    expect_status("RC_WRITE_ENCODE", status, RDMA_SC_OK);
    wire_packet = new();
    wire_packet.unpack(frame_bytes);
    roce = wire_packet.get_rocev2();
    if (roce == null || roce.opcode != RC_RDMA_WRITE_ONLY ||
        roce.reth_dma_len != source.payload.size())
      `uvm_error("RC_WRITE_RETH", "RC WRITE RETH projection mismatch")
  endtask

  // 功能：验证 URC 使用 XTR URC opcode（defs.h xtrdma_urc_pkt_opcode_type，0b110 前缀）：SEND ONLY
  //   为 0xC4、READ 请求 FIRST 为 0xCD、ACK 为 0xD1，解码回 URC 语义；READ 响应只能单包
  //   （READ_DATA_ONLY），FIRST 分段被拒。
  // 输入/输出及副作用：codec（输入）；只编码/解码本地 packet 快照。
  // 失败/边界：opcode、transport、segment 不符或非法组合被接受时报告错误。
  task automatic test_urc_opcodes(
    rdma_netpkt_codec codec
  );
    rdma_packet source;
    rdma_packet decoded;
    packet wire_packet;
    rocev2_bth roce;
    byte unsigned frame_bytes[$];
    rdma_network_opcode_e ops[3];
    rdma_packet_segment_e segs[3];
    bit [7:0] wire_ops[3];
    rdma_status status;

    ops = '{RDMA_NET_SEND, RDMA_NET_RDMA_READ_REQUEST, RDMA_NET_ACK};
    segs = '{RDMA_SEG_ONLY, RDMA_SEG_FIRST, RDMA_SEG_ONLY};
    wire_ops = '{8'hc4, 8'hcd, 8'hd1};
    foreach (ops[k]) begin
      source = make_rdma_packet("urc_op", RDMA_TRANSPORT_URC, ops[k]);
      source.segment = segs[k];
      if (ops[k] != RDMA_NET_SEND)
        source.payload.delete();
      source.pack_headers();
      frame_bytes.delete();
      status = codec.encode(source, frame_bytes);
      expect_status("URC_OP_ENCODE", status, RDMA_SC_OK);
      wire_packet = new();
      wire_packet.unpack(frame_bytes);
      roce = wire_packet.get_rocev2();
      if (roce == null || roce.opcode != wire_ops[k])
        `uvm_error("URC_OP", $sformatf("%s/%s encoded as %02h, expected %02h", ops[k].name(),
                                       segs[k].name(), roce == null ? 8'h0 : roce.opcode,
                                       wire_ops[k]))
      status = codec.decode(frame_bytes, decoded);
      expect_status("URC_OP_DECODE", status, RDMA_SC_OK);
      if (decoded == null || decoded.transport != RDMA_TRANSPORT_URC ||
          decoded.opcode != ops[k] || decoded.segment != segs[k])
        `uvm_error("URC_OP_DECODE", $sformatf("%s/%s did not round-trip", ops[k].name(),
                                              segs[k].name()))
    end
    source = make_rdma_packet("urc_read_resp", RDMA_TRANSPORT_URC, RDMA_NET_RDMA_READ_RESP);
    source.segment = RDMA_SEG_FIRST;
    frame_bytes.delete();
    status = codec.encode(source, frame_bytes);
    expect_status("URC_READ_RESP_ENCODE", status, RDMA_SC_UNSUPPORTED_OPCODE);
    if (frame_bytes.size() != 0)
      `uvm_error("URC_READ_RESP_FRAME", "unsupported URC READ response left encoded bytes")
  endtask

  // 功能：验证 RC compare-and-swap 使用 RoCEv2 AtomicETH 和对应 opcode，
  //   防止端到端测试把原子请求降级为普通 SEND。
  // 输入/输出及副作用：codec（输入）；只编码/解码本地 packet 快照，
  //   不涉及队列或主机内存。
  // 失败/边界：必须观察 RC_CMP_SWAP 及完整 VA/r_key/swap/compare 字段，
  //   解码后的语义 opcode 也必须保持 ATOMIC_CMP_SWAP。
  task automatic test_rc_atomic_round_trip(
    rdma_netpkt_codec codec
  );
    rdma_packet source;
    rdma_packet decoded;
    packet wire_packet;
    byte unsigned frame_bytes[$];
    rdma_status status;
    rocev2_bth roce;

    source = make_rdma_packet("rc_atomic", RDMA_TRANSPORT_RC,
                              RDMA_NET_ATOMIC_CMP_SWAP);
    source.header_bytes = '{8'h11, 8'h11, 8'h22, 8'h22,
                            8'h33, 8'h33, 8'h44, 8'h44,
                            8'haa, 8'hbb, 8'hcc, 8'hdd,
                            8'h55, 8'h55, 8'h66, 8'h66,
                            8'h77, 8'h77, 8'h88, 8'h88,
                            8'h99, 8'h99, 8'haa, 8'haa,
                            8'hbb, 8'hbb, 8'hcc, 8'hcc};
    status = codec.encode(source, frame_bytes);
    expect_status("RC_ATOMIC_ENCODE", status, RDMA_SC_OK);
    wire_packet = new();
    wire_packet.unpack(frame_bytes);
    roce = wire_packet.get_rocev2();
    if (roce == null || roce.opcode != RC_CMP_SWAP ||
        roce.atomic_va != 64'h1111_2222_3333_4444 ||
        roce.atomic_r_key != 32'haabb_ccdd ||
        roce.atomic_swap_add != 64'h5555_6666_7777_8888 ||
        roce.atomic_compare != 64'h9999_aaaa_bbbb_cccc)
      `uvm_error("RC_ATOMIC_HEADER", "RC atomic header projection mismatch")
    status = codec.decode(frame_bytes, decoded);
    expect_status("RC_ATOMIC_DECODE", status, RDMA_SC_OK);
    if (decoded == null || decoded.transport != RDMA_TRANSPORT_RC ||
        decoded.opcode != RDMA_NET_ATOMIC_CMP_SWAP ||
        decoded.destination_qpn != source.destination_qpn ||
        decoded.psn != source.psn)
      `uvm_error("RC_ATOMIC_FIELDS", "RC atomic semantic round-trip mismatch")
  endtask

  // 功能：验证 RC fetch-add 使用独立的 RoCEv2 AtomicETH opcode，并按协议
  //   将 compare 字段归零，防止把 compare-swap 的字段布局误用于加法原子。
  // 输入/输出及副作用：codec（输入）；只编码/解码本地 packet 快照，不提交
  //   队列或主机内存。
  // 失败/边界：必须观察 RC_FETCH_ADD、VA/r_key/swap_add 和 compare=0，且
  //   解码后的语义 opcode 保持 ATOMIC_FETCH_ADD。
  task automatic test_rc_atomic_fetch_add_round_trip(
    rdma_netpkt_codec codec
  );
    rdma_packet source;
    rdma_packet decoded;
    packet wire_packet;
    byte unsigned frame_bytes[$];
    rdma_status status;
    rocev2_bth roce;

    source = make_rdma_packet("rc_fetch_add", RDMA_TRANSPORT_RC,
                              RDMA_NET_ATOMIC_FETCH_ADD);
    source.header_bytes = '{8'h21, 8'h21, 8'h32, 8'h32,
                            8'h43, 8'h43, 8'h54, 8'h54,
                            8'hba, 8'had, 8'hf0, 8'h0d,
                            8'h65, 8'h65, 8'h76, 8'h76,
                            8'h87, 8'h87, 8'h98, 8'h98,
                            8'ha9, 8'ha9, 8'hba, 8'hba,
                            8'hcb, 8'hcb, 8'hdc, 8'hdc};
    status = codec.encode(source, frame_bytes);
    expect_status("RC_FETCH_ADD_ENCODE", status, RDMA_SC_OK);
    wire_packet = new();
    wire_packet.unpack(frame_bytes);
    roce = wire_packet.get_rocev2();
    if (roce == null || roce.opcode != RC_FETCH_ADD ||
        roce.atomic_va != 64'h2121_3232_4343_5454 ||
        roce.atomic_r_key != 32'hbaad_f00d ||
        roce.atomic_swap_add != 64'h6565_7676_8787_9898 ||
        roce.atomic_compare != 64'h0)
      `uvm_error("RC_FETCH_ADD_HEADER", "RC fetch-add AtomicETH mismatch")
    status = codec.decode(frame_bytes, decoded);
    expect_status("RC_FETCH_ADD_DECODE", status, RDMA_SC_OK);
    if (decoded == null || decoded.transport != RDMA_TRANSPORT_RC ||
        decoded.opcode != RDMA_NET_ATOMIC_FETCH_ADD ||
        decoded.destination_qpn != source.destination_qpn ||
        decoded.psn != source.psn)
      `uvm_error("RC_FETCH_ADD_FIELDS", "RC fetch-add semantic round-trip mismatch")
  endtask

  // 功能：验证 UD SEND 使用 DETH，并保留源 QP/Q_Key 所需的 UD 结构。
  // 输入/输出及副作用：codec（输入）；只读检查生成 frame，不推进任何 RDMA ring。
  // 失败/边界：UD 报文必须含 DETH；适配器错误地生成 RC opcode 时报告错误。
  task automatic test_ud_send_deth(
    rdma_netpkt_codec codec
  );
    rdma_packet source;
    packet wire_packet;
    byte unsigned frame_bytes[$];
    rdma_status status;
    rocev2_bth roce;

    source = make_rdma_packet("ud_send", RDMA_TRANSPORT_UD, RDMA_NET_SEND);
    status = codec.encode(source, frame_bytes);
    expect_status("UD_SEND_ENCODE", status, RDMA_SC_OK);
    wire_packet = new();
    wire_packet.unpack(frame_bytes);
    roce = wire_packet.get_rocev2();
    if (roce == null || roce.opcode != UD_SEND_ONLY || !roce.has_deth() ||
        roce.deth_src_qp != source.source_qpn)
      `uvm_error("UD_SEND_DETH", "UD SEND DETH projection mismatch")
  endtask

  // 功能：翻转帧中 ICRC 前的一个负载字节后解码须失败（ICRC 校验）。
  // 输入/输出及副作用：codec（输入）；只编解码本地快照。
  // 失败/边界：损坏的帧被接受时报告错误。
  task automatic test_icrc_corruption(rdma_netpkt_codec codec);
    rdma_packet source;
    rdma_packet decoded;
    byte unsigned frame_bytes[$];

    source = make_rdma_packet("rc_send_bad", RDMA_TRANSPORT_RC, RDMA_NET_SEND);
    expect_status("CORRUPT_ENCODE", codec.encode(source, frame_bytes), RDMA_SC_OK);
    frame_bytes[frame_bytes.size() - 6] ^= 8'h01;
    expect_status("CORRUPT_DECODE", codec.decode(frame_bytes, decoded), RDMA_SC_CODEC_ERROR);
  endtask

  // 功能：依次执行全部用例。
  // 输入/输出及副作用：持有 objection 直到结束。
  // 失败/边界：任一用例报错由 UVM 汇总为测试失败。
  task run_phase(uvm_phase phase);
    rdma_netpkt_codec codec;

    phase.raise_objection(this);
    codec = rdma_netpkt_codec::type_id::create("codec");
    test_rc_send_round_trip(codec);
    test_rc_write_reth(codec);
    test_rc_atomic_round_trip(codec);
    test_rc_atomic_fetch_add_round_trip(codec);
    test_urc_opcodes(codec);
    test_ud_send_deth(codec);
    test_icrc_corruption(codec);
    phase.drop_objection(this);
  endtask
endclass
