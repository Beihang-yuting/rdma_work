// 目录：测试层 integration/rdma_net_packet_adapter_test.sv。
// 职责：验证 net_packet 适配器的 RoCEv2/iWARP 报文生成、解析、快照所有权和故障策略。
// 依赖：rdma_net_packet_adapter_pkg、rdma_net_packet_bridge_pkg 及外部 net_packet packet 类。
// 所有权与生命周期：测试只拥有本地 adapter、sink 和 packet 快照；适配器不释放外部 packet。

// 中文说明：该测试只在 RDMA_NET_PACKET 编译开关下进入测试包，避免 core suite 依赖外部协议实现。
class rdma_net_packet_adapter_test extends uvm_test;
  `uvm_component_utils(rdma_net_packet_adapter_test)

  // 功能：构造 net_packet 适配器测试组件并建立 UVM 层级名称。
  // 输入/输出及副作用：name、parent（输入）；只初始化 UVM 组件，不创建外部网络资源。
  // 失败/边界：父组件为空由 UVM 处理；测试资源在 run_phase 内显式创建并在结束后失效。
  function new(string name = "rdma_net_packet_adapter_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：创建合法的 PF Function identity，供适配器验证 UID、generation 和 reset epoch。
  // 输入/输出及副作用：name（输入）；返回独立 identity 快照，不修改 dpu_common 或外部路由表。
  // 失败/边界：返回对象若 validate 失败，调用方必须把它视为测试夹具错误而停止发送。
  function automatic rdma_function_identity make_identity(string name);
    rdma_function_identity identity;

    identity = rdma_function_identity::type_id::create(name);
    identity.key = '{root_id:16'h1,
                    host_topology_key:32'h100,
                    function_kind:RDMA_FUNCTION_PF,
                    parent_pf_bdf:'0,
                    vf_index:'0,
                    bdf:'0};
    identity.key.bdf = '{segment:16'h0, bus:8'h2, device:5'h0,
                         function_num:3'h0};
    identity.function_uid = 64'h1000_0000_0000_0001;
    identity.global_function_id = 32'h10;
    identity.generation = 32'd7;
    identity.reset_epoch = 64'd3;
    return identity;
  endfunction

  // 功能：创建带固定 payload 和 QP/PSN 的 RDMA 语义报文，作为编码输入快照。
  // 输入/输出及副作用：transport、opcode、name（输入）；返回本地 rdma_packet，不拥有 host-mem/队列资源。
  // 失败/边界：payload 为空仍是合法零长度 SEND；未知 transport/opcode 由适配器返回明确错误。
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

  // 功能：比较两个 byte queue 是否逐字节相等，确认 sink 接收的是值快照且故障注入可观测。
  // 输入/输出及副作用：lhs、rhs（输入）；只读比较并返回 bit，不修改任何 packet 或适配器状态。
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

  // 功能：检查状态码并在测试日志中保留适配器失败原因。
  // 输入/输出及副作用：tag、status、expected（输入）；失败通过 UVM error 报告，不推进任何生产游标。
  // 失败/边界：status 为空时报告独立错误并结束本次检查，避免解引用空句柄。
  function automatic void expect_status(
    string tag,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null) begin
      `uvm_error(tag, "adapter returned null status")
      return;
    end
    if (status.code != expected)
      `uvm_error(tag, $sformatf("expected %s, got %s: %s",
                               expected.name(), status.code.name(),
                               status.message))
  endfunction

  // 功能：test_transport_capability_matrix 校验 net_packet 适配器对每种
  //   transport 的实际 wire opcode 白名单，防止 queue-data 先接受而编码阶段
  //   才发现外部 profile 不支持。
  // 输入/输出及副作用：无显式参数；只读取 capability 函数结果，不创建
  //   packet 或访问 sink/host-memory。
  // 失败/边界：UD SEND_WITH_INV、URC READ/LOCAL_INVALIDATE 以及 CUSTOM
  //   均必须返回 0；RC SEND/WRITE/READ/ATOMIC 和 UD/URC 支持项必须返回 1。
  task automatic test_transport_capability_matrix();
    if (!rdma_net_packet_work_opcode_supported_for_transport(
          RDMA_TRANSPORT_RC, RDMA_WR_RDMA_READ) ||
        !rdma_net_packet_work_opcode_supported_for_transport(
          RDMA_TRANSPORT_RC, RDMA_WR_ATOMIC_FETCH_ADD) ||
        !rdma_net_packet_work_opcode_supported_for_transport(
          RDMA_TRANSPORT_UD, RDMA_WR_SEND) ||
        !rdma_net_packet_work_opcode_supported_for_transport(
          RDMA_TRANSPORT_URC, RDMA_WR_RDMA_WRITE))
      `uvm_error("CAP_MATRIX_POSITIVE", "supported wire opcode was rejected")
    if (rdma_net_packet_work_opcode_supported_for_transport(
          RDMA_TRANSPORT_UD, RDMA_WR_SEND_WITH_INV) ||
        rdma_net_packet_work_opcode_supported_for_transport(
          RDMA_TRANSPORT_URC, RDMA_WR_RDMA_READ) ||
        rdma_net_packet_work_opcode_supported_for_transport(
          RDMA_TRANSPORT_URC, RDMA_WR_LOCAL_INVALIDATE) ||
        rdma_net_packet_work_opcode_supported_for_transport(
          RDMA_TRANSPORT_CUSTOM, RDMA_WR_SEND))
      `uvm_error("CAP_MATRIX_NEGATIVE", "unsupported wire opcode was accepted")
  endtask

  // 功能：验证 RC SEND 生成 RoCEv2 BTH、调用 net_packet do_pack 并可由 parser 解回语义字段。
  // 输入/输出及副作用：adapter、identity、frame_bytes（局部输出）；只更新测试快照，不修改队列 PI/CI。
  // 失败/边界：缺少外层 Ethernet/IP/UDP/RoCE layer、QPN/PSN 或 payload 不一致均报告错误。
  task automatic test_rc_send_round_trip(
    rdma_net_packet_adapter adapter,
    rdma_function_identity identity
  );
    rdma_packet source;
    rdma_packet decoded;
    byte unsigned frame_bytes[$];
    rdma_status status;

    source = make_rdma_packet("rc_send", RDMA_TRANSPORT_RC, RDMA_NET_SEND);
    status = adapter.encode_packet(source, frame_bytes);
    expect_status("RC_SEND_ENCODE", status, RDMA_SC_OK);
    if (frame_bytes.size() < 64)
      `uvm_error("RC_SEND_FRAME", $sformatf("frame too short: %0d", frame_bytes.size()))
    status = adapter.decode_packet(frame_bytes, decoded);
    expect_status("RC_SEND_DECODE", status, RDMA_SC_OK);
    if (decoded == null || decoded.transport != RDMA_TRANSPORT_RC ||
        decoded.opcode != RDMA_NET_SEND ||
        decoded.destination_qpn != source.destination_qpn ||
        decoded.psn != source.psn ||
        !bytes_equal(decoded.payload, source.payload))
      `uvm_error("RC_SEND_FIELDS", "RC SEND semantic round-trip mismatch")
  endtask

  // 功能：验证 RC WRITE 生成 RETH，并将 payload 长度投影到 RETH DMA length。
  // 输入/输出及副作用：adapter、identity（输入）；仅生成和解析值快照，不改变 host-mem 映射。
  // 失败/边界：RoCEv2 layer 缺失、RETH 长度错误或解析 opcode 不一致时报告错误。
  task automatic test_rc_write_reth(
    rdma_net_packet_adapter adapter
  );
    rdma_packet source;
    packet wire_packet;
    byte unsigned frame_bytes[$];
    rdma_status status;
    rocev2_bth roce;

    source = make_rdma_packet("rc_write", RDMA_TRANSPORT_RC,
                              RDMA_NET_RDMA_WRITE);
    status = adapter.encode_packet(source, frame_bytes);
    expect_status("RC_WRITE_ENCODE", status, RDMA_SC_OK);
    wire_packet = new();
    wire_packet.unpack(frame_bytes);
    roce = wire_packet.get_rocev2();
    if (roce == null || roce.opcode != RC_RDMA_WRITE_ONLY ||
        roce.reth_dma_len != source.payload.size())
      `uvm_error("RC_WRITE_RETH", "RC WRITE RETH projection mismatch")
  endtask

  // 功能：验证 URC/UC wire profile 不接受 RDMA READ request，避免把非法
  //   语义映射成 RC READ opcode 后发送到网络。
  // 输入/输出及副作用：adapter（输入）；frame_bytes、status（局部输出）；
  //   只执行纯编码，不触碰 sink、队列游标或 host-memory。
  // 失败/边界：encode_packet 必须返回 RDMA_SC_UNSUPPORTED_OPCODE，并保持
  //   输出 frame 为空；任何成功编码或残留半包都属于协议边界错误。
  task automatic test_urc_read_rejected(
    rdma_net_packet_adapter adapter
  );
    rdma_packet source;
    byte unsigned frame_bytes[$];
    rdma_status status;

    source = make_rdma_packet("urc_read", RDMA_TRANSPORT_URC,
                              RDMA_NET_RDMA_READ_REQUEST);
    status = adapter.encode_packet(source, frame_bytes);
    expect_status("URC_READ_ENCODE", status, RDMA_SC_UNSUPPORTED_OPCODE);
    if (frame_bytes.size() != 0)
      `uvm_error("URC_READ_FRAME", "unsupported URC READ left encoded bytes")
  endtask

  // 功能：验证 RC compare-and-swap 使用 RoCEv2 AtomicETH 和对应 opcode，
  //   防止端到端测试把原子请求降级为普通 SEND。
  // 输入/输出及副作用：adapter（输入）；只编码/解码本地 packet 快照，
  //   不提交 sink、queue 或 host-memory 事务。
  // 失败/边界：必须观察 RC_CMP_SWAP 及完整 VA/r_key/swap/compare 字段，
  //   解码后的语义 opcode 也必须保持 ATOMIC_CMP_SWAP。
  task automatic test_rc_atomic_round_trip(
    rdma_net_packet_adapter adapter
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
    status = adapter.encode_packet(source, frame_bytes);
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
    status = adapter.decode_packet(frame_bytes, decoded);
    expect_status("RC_ATOMIC_DECODE", status, RDMA_SC_OK);
    if (decoded == null || decoded.transport != RDMA_TRANSPORT_RC ||
        decoded.opcode != RDMA_NET_ATOMIC_CMP_SWAP ||
        decoded.destination_qpn != source.destination_qpn ||
        decoded.psn != source.psn)
      `uvm_error("RC_ATOMIC_FIELDS", "RC atomic semantic round-trip mismatch")
  endtask

  // 功能：验证 RC fetch-add 使用独立的 RoCEv2 AtomicETH opcode，并按协议
  //   将 compare 字段归零，防止把 compare-swap 的字段布局误用于加法原子。
  // 输入/输出及副作用：adapter（输入）；只编码/解码本地 packet 快照，不提交
  //   sink、queue 或 host-memory 事务。
  // 失败/边界：必须观察 RC_FETCH_ADD、VA/r_key/swap_add 和 compare=0，且
  //   解码后的语义 opcode 保持 ATOMIC_FETCH_ADD。
  task automatic test_rc_atomic_fetch_add_round_trip(
    rdma_net_packet_adapter adapter
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
    status = adapter.encode_packet(source, frame_bytes);
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
    status = adapter.decode_packet(frame_bytes, decoded);
    expect_status("RC_FETCH_ADD_DECODE", status, RDMA_SC_OK);
    if (decoded == null || decoded.transport != RDMA_TRANSPORT_RC ||
        decoded.opcode != RDMA_NET_ATOMIC_FETCH_ADD ||
        decoded.destination_qpn != source.destination_qpn ||
        decoded.psn != source.psn)
      `uvm_error("RC_FETCH_ADD_FIELDS", "RC fetch-add semantic round-trip mismatch")
  endtask

  // 功能：验证 UD SEND 使用 DETH，并保留源 QP/Q_Key 所需的 UD 结构。
  // 输入/输出及副作用：adapter（输入）；只读检查生成 frame，不推进任何 RDMA ring。
  // 失败/边界：UD 报文必须含 DETH；适配器错误地生成 RC opcode 时报告错误。
  task automatic test_ud_send_deth(
    rdma_net_packet_adapter adapter
  );
    rdma_packet source;
    packet wire_packet;
    byte unsigned frame_bytes[$];
    rdma_status status;
    rocev2_bth roce;

    source = make_rdma_packet("ud_send", RDMA_TRANSPORT_UD, RDMA_NET_SEND);
    status = adapter.encode_packet(source, frame_bytes);
    expect_status("UD_SEND_ENCODE", status, RDMA_SC_OK);
    wire_packet = new();
    wire_packet.unpack(frame_bytes);
    roce = wire_packet.get_rocev2();
    if (roce == null || roce.opcode != UD_SEND_ONLY || !roce.has_deth() ||
        roce.deth_src_qp != source.source_qpn)
      `uvm_error("UD_SEND_DETH", "UD SEND DETH projection mismatch")
  endtask

  // 功能：验证 iWARP 走 TCP/MPA+DDP+RDMAP 头并能完成接收解析。
  // 输入/输出及副作用：adapter（输入）；frame_bytes/decoded 为本地值快照，不取得外部 TCP 资源所有权。
  // 失败/边界：缺少 iWARP layer、TCP 外层或 payload 解析不一致时报告错误。
  task automatic test_iwarp_round_trip(
    rdma_net_packet_adapter adapter
  );
    rdma_packet source;
    rdma_packet decoded;
    byte unsigned frame_bytes[$];
    rdma_status status;

    source = make_rdma_packet("iwarp_send", RDMA_TRANSPORT_CUSTOM,
                              RDMA_NET_SEND);
    status = adapter.encode_packet(source, frame_bytes);
    expect_status("IWARP_ENCODE", status, RDMA_SC_OK);
    status = adapter.decode_packet(frame_bytes, decoded);
    expect_status("IWARP_DECODE", status, RDMA_SC_OK);
    if (decoded == null || decoded.transport != RDMA_TRANSPORT_CUSTOM ||
        !bytes_equal(decoded.payload, source.payload))
      `uvm_error("IWARP_FIELDS", "iWARP semantic round-trip mismatch")
  endtask

  // 功能：验证 sink 发送、接收和 drop/corrupt/delay 故障策略只在 adapter 层生效。
  // 输入/输出及副作用：adapter、sink、identity（输入）；更新 sink 的本地队列和 adapter 统计，不修改 SQ/CQ。
  // 失败/边界：drop 必须不调用 sink.send；corrupt 必须改变 raw byte；delay 只记录延迟不阻塞永久。
  task automatic test_sink_and_fault_policy(
    rdma_net_packet_adapter adapter,
    rdma_net_packet_queue_sink sink
  );
    rdma_packet source;
    rdma_packet received;
    rdma_net_response_policy policy;
    rdma_net_fault fault;
    rdma_status status;
    int unsigned sent_before;

    source = make_rdma_packet("sink_send", RDMA_TRANSPORT_RC, RDMA_NET_SEND);
    adapter.send_packet(source, status);
    expect_status("SINK_SEND", status, RDMA_SC_OK);
    if (sink.sent_count != 1)
      `uvm_error("SINK_COUNT", "sink did not receive the packet")
    sink.enqueue_last_sent_for_receive();
    adapter.receive_packet(received, status);
    expect_status("SINK_RECEIVE", status, RDMA_SC_OK);
    if (received == null || received.payload.size() != source.payload.size())
      `uvm_error("SINK_RECEIVE_FIELDS", "sink receive payload mismatch")

    policy = rdma_net_response_policy::type_id::create("drop_policy");
    policy.drop_every_n = 1;
    status = adapter.configure_response_policy(policy);
    expect_status("DROP_POLICY", status, RDMA_SC_OK);
    sent_before = sink.sent_count;
    adapter.send_packet(source, status);
    expect_status("DROP_SEND", status, RDMA_SC_OK);
    if (sink.sent_count != sent_before)
      `uvm_error("DROP_POLICY_EFFECT", "drop policy still called sink")

    policy.drop_every_n = 0;
    policy.corrupt_every_n = 1;
    status = adapter.configure_response_policy(policy);
    expect_status("CORRUPT_POLICY", status, RDMA_SC_OK);
    adapter.send_packet(source, status);
    expect_status("CORRUPT_SEND", status, RDMA_SC_OK);
    if (sink.last_raw.size() == 0 || bytes_equal(sink.last_raw, sink.previous_raw))
      `uvm_error("CORRUPT_POLICY_EFFECT", "corruption did not alter raw bytes")

    fault = rdma_net_fault::type_id::create("delay_fault");
    fault.delay_cycles = 1;
    fault.corrupt_byte = 1;
    fault.corrupt_byte_index = 0;
    fault.corrupt_xor_mask = 8'h80;
    status = adapter.inject_fault(fault);
    expect_status("FAULT_INJECT", status, RDMA_SC_OK);
    adapter.send_packet(source, status);
    expect_status("FAULT_SEND", status, RDMA_SC_OK);
  endtask

  // 功能：执行 net_packet adapter 的所有场景，并在结束时释放 UVM objection。
  // 输入/输出及副作用：phase（输入）；创建本地 adapter/sink、执行测试任务并产生 UVM 报告。
  // 失败/边界：Function identity 无效、sink 绑定失败或任一场景报错均由 UVM 汇总为测试失败。
  task run_phase(uvm_phase phase);
    rdma_function_identity identity;
    rdma_net_packet_queue_sink sink;
    rdma_net_packet_adapter adapter;

    phase.raise_objection(this);
    identity = make_identity("net_packet_function");
    sink = new("net_packet_sink");
    adapter = new("net_packet_adapter", sink);
    expect_status("FUNCTION_BIND", adapter.configure_function(identity), RDMA_SC_OK);
    test_rc_send_round_trip(adapter, identity);
    test_transport_capability_matrix();
    test_rc_write_reth(adapter);
    test_rc_atomic_round_trip(adapter);
    test_rc_atomic_fetch_add_round_trip(adapter);
    test_urc_read_rejected(adapter);
    test_ud_send_deth(adapter);
    test_iwarp_round_trip(adapter);
    test_sink_and_fault_policy(adapter, sink);
    phase.drop_objection(this);
  endtask
endclass
