// 目录：外部适配器实现层 adapters/net_packet/rdma_net_packet_adapter_pkg.sv。
// 职责：把 RDMA 语义报文转换为 net_packet packet，并在接收方向解析回 detached rdma_packet。
// 依赖：rdma_adapter_pkg、rdma_model_pkg，以及由 net_packet/src/core/packet.sv 提供的 packet 类。
// 所有权与生命周期：adapter 只拥有 Function/policy/fault 的值快照；sink 和外部 packet 均为非拥有引用。

// 中文说明：本文件只在 RDMA_NET_PACKET suite 编译，避免 RDMA core 依赖外部协议实现。
package rdma_net_packet_adapter_pkg;
  // 上游 packet/header 声明在编译单元作用域，VCS 不允许 package 内 forward typedef 绑定
  // 外部 $unit 类；故在本 package 内 include packet.sv，使协议类型同处一个作用域。
  `include "packet.sv"
  import uvm_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_adapter_pkg::*;
  `include "uvm_macros.svh"

  // 功能：判断 transport/opcode 是否在本适配器的 RoCEv2 wire 能力内，供上层提交前预检。
  // 输入/输出及副作用：transport、opcode 输入；返回 bit，无副作用。
  // 失败/边界：UD 仅 SEND/SEND_WITH_IMM；URC 仅 SEND/WRITE 及 WITH_IMM；RC 另含 READ/ATOMIC；
  //   其余（控制 WQE、SEND_WITH_INV 等）返回 0，调用方须在 encode 前 fail-closed。
  function automatic bit rdma_net_packet_work_opcode_supported_for_transport(
    rdma_transport_e transport,
    rdma_work_opcode_e opcode
  );
    case (transport)
      RDMA_TRANSPORT_RC:
        return opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM,
                              RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM,
                              RDMA_WR_RDMA_READ,
                              RDMA_WR_ATOMIC_CMP_SWAP,
                              RDMA_WR_ATOMIC_FETCH_ADD};
      RDMA_TRANSPORT_UD:
        return opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM};
      RDMA_TRANSPORT_URC:
        return opcode inside {RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM,
                              RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM};
      default:
        return 1'b0;
    endcase
  endfunction

  // 功能：定义 net_packet 适配器与外部发送/接收环境之间的最小边界。
  // 输入/输出及副作用：send/receive 只传递 packet 值快照和状态，不改变 RDMA 队列游标。
  // 失败/边界：实现必须在 packet 为空、后端拒绝或外部资源未配置时返回明确错误。
  virtual class rdma_net_packet_sink extends uvm_object;
    // 功能：构造 sink 基类对象并建立 UVM 名称。
    // 输入/输出及副作用：name（输入）；只初始化 UVM 对象，不取得外部 packet 所有权。
    // 失败/边界：构造阶段不做后端连接；未绑定实现时 send/receive 不可调用。
    function new(string name = "rdma_net_packet_sink");
      super.new(name);
    endfunction

    // 功能：向外部网络环境提交一个已经完成 pack 的 packet。
    // 输入/输出及副作用：pkt（输入）、status（输出）；实现可读取 raw_data 但不得释放或修改调用方对象。
    // 失败/边界：后端未激活、packet 为空或写入失败时返回错误，不能伪造成功。
    pure virtual task send(packet pkt, output rdma_status status);

    // 功能：从外部网络环境取出一个 packet 值快照。
    // 输入/输出及副作用：pkt、status（输出）；实现发布新的 packet 引用，生命周期仍由 sink 管理。
    // 失败/边界：没有可用报文时返回 RDMA_SC_QUEUE_EMPTY，不返回陈旧句柄。
    pure virtual task receive(output packet pkt, output rdma_status status);
  endclass

  class rdma_net_packet_adapter extends rdma_net_api;
    `rdma_object_utils(rdma_net_packet_adapter)

    local rdma_net_packet_sink sink;
    local rdma_function_identity authority;
    local rdma_net_response_policy response_policy;
    local rdma_net_fault pending_fault;
    local rdma_net_observer observers[$];

    longint unsigned send_sequence;
    longint unsigned receive_sequence;
    int unsigned dropped_count;
    int unsigned corrupted_count;
    longint unsigned delayed_cycles;
    packet last_sent_packet;

    // 功能：构造 net_packet adapter，保存 sink 的非拥有引用并清零统计量。
    // 输入/输出及副作用：name、sink（输入）；初始化本地字段，不创建或释放外部网络环境。
    // 失败/边界：sink 可为空以便先构造后绑定；未绑定 sink 时 send/receive 返回 INVALID_STATE。
    function new(string name = "rdma_net_packet_adapter",
                 rdma_net_packet_sink sink = null);
      super.new(name);
      this.sink = sink;
      authority = null;
      response_policy = null;
      pending_fault = null;
      observers.delete();
      send_sequence = 0;
      receive_sequence = 0;
      dropped_count = 0;
      corrupted_count = 0;
      delayed_cycles = 0;
      last_sent_packet = null;
    endfunction

    // 功能：绑定一个 detached Function identity，作为所有网络事务的 authority。
    // 输入/输出及副作用：identity（输入）；成功时克隆 identity 并替换本地快照，不修改输入对象。
    // 失败/边界：identity 为空、UID/generation/route 非法或 clone/cast 失败时保持旧快照并返回错误。
    function rdma_status configure_function(rdma_function_identity identity);
      rdma_function_identity candidate;
      rdma_status status;

      if (identity == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "Function identity is null");
      status = identity.validate();
      if (status == null || !status.ok())
        return (status == null) ?
               rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "Function identity validation returned null") :
               status;
      if (!rdma_deep_copy#(rdma_function_identity)::try_of(identity, candidate))
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "Function identity clone failed");
      authority = candidate;
      return rdma_status::success();
    endfunction

    // 功能：替换发送/接收 sink 的非拥有引用，供外部 AXIS/PCAP/DUT 环境装配。
    // 输入/输出及副作用：new_sink（输入）；成功时只更新本地句柄，不释放旧 sink。
    // 失败/边界：new_sink 为空时拒绝绑定并保留旧 sink，避免运行态静默丢包。
    function rdma_status configure_sink(rdma_net_packet_sink new_sink);
      if (new_sink == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "net_packet sink is null");
      sink = new_sink;
      return rdma_status::success();
    endfunction

    // 功能：检查 Function authority 是否仍是完整、可用的本地快照。
    // 输入/输出及副作用：无显式输入；只读 authority 并返回状态，不改变代际或 reset epoch。
    // 失败/边界：authority 为空或 validate 失败时禁止任何 packet I/O。
    function rdma_status validate_authority();
      if (authority == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "Function authority is not configured");
      return authority.validate();
    endfunction

    // 功能：将当前 authority 投影为 detached 快照，供上层记录多 Host/PF/VF 路由证据。
    // 输入/输出及副作用：snapshot（输出）；成功时复制 authority，不泄露内部可变句柄。
    // 失败/边界：未配置 authority 或 clone 失败时返回错误且 snapshot 保持为空。
    function rdma_status function_snapshot(
      output rdma_function_identity snapshot
    );
      uvm_object cloned_object;

      snapshot = null;
      if (authority == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "Function authority is not configured");
      cloned_object = authority.clone();
      if (cloned_object == null || !$cast(snapshot, cloned_object)) begin
        snapshot = null;
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "Function authority snapshot failed");
      end
      return rdma_status::success();
    endfunction

    // 功能：按幂等规则复制网络响应策略，供发送路径决定 drop/corrupt/delay。
    // 输入/输出及副作用：policy（输入）；成功时替换策略快照，不修改调用方对象。
    // 失败/边界：policy 为空、周期为零以外的非法值或 clone 失败时保留旧策略。
    virtual function rdma_status configure_response_policy(
      rdma_net_response_policy policy
    );
      rdma_net_response_policy candidate;

      if (policy == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "network response policy is null");
      if (!rdma_deep_copy#(rdma_net_response_policy)::try_of(policy, candidate))
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "network response policy clone failed");
      response_policy = candidate;
      return rdma_status::success();
    endfunction

    // 功能：登记一个只读 observer，在发送或接收成功后收到 detached rdma_packet。
    // 输入/输出及副作用：observer（输入）；成功时保存非拥有引用，不复制或释放 observer。
    // 失败/边界：observer 为空或重复登记时拒绝，保持已有 observer 列表不变。
    virtual function void register_observer(rdma_net_observer observer);
      if (observer == null)
        return;
      foreach (observers[i]) begin
        if (observers[i] == observer)
          return;
      end
      observers.push_back(observer);
    endfunction

    // 功能：复制一次性故障描述，供下一次 adapter I/O 使用。
    // 输入/输出及副作用：fault（输入）；成功时替换 pending_fault 快照，不修改调用方故障对象。
    // 失败/边界：fault 为空或 clone/cast 失败时返回错误；不会部分注入故障。
    virtual function rdma_status inject_fault(rdma_net_fault fault);
      rdma_net_fault candidate;

      if (fault == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "network fault is null");
      if (!rdma_deep_copy#(rdma_net_fault)::try_of(fault, candidate))
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "network fault clone failed");
      pending_fault = candidate;
      return rdma_status::success();
    endfunction

    // 功能：从大端 byte queue 读取 32 位扩展头字段。
    // 输入/输出及副作用：bytes、offset（输入）、value（输出）；只读解析，不修改输入队列。
    // 失败/边界：长度不足时返回 0，由上层按缺失扩展字段处理。
    static function bit [31:0] read_be32(
      byte unsigned bytes[$],
      int unsigned offset
    );
      bit [31:0] value;

      value = '0;
      if (offset + 4 > bytes.size())
        return value;
      value = {bytes[offset], bytes[offset + 1],
               bytes[offset + 2], bytes[offset + 3]};
      return value;
    endfunction

    // 功能：从大端 byte queue 读取 64 位 RETH/Atomic 地址字段。
    // 输入/输出及副作用：bytes、offset（输入）；只读拼接并返回 64 位值。
    // 失败/边界：长度不足时返回 0，不越界访问或伪造地址。
    static function bit [63:0] read_be64(
      byte unsigned bytes[$],
      int unsigned offset
    );
      bit [63:0] value;

      value = '0;
      if (offset + 8 > bytes.size())
        return value;
      value = {bytes[offset], bytes[offset + 1],
               bytes[offset + 2], bytes[offset + 3],
               bytes[offset + 4], bytes[offset + 5],
               bytes[offset + 6], bytes[offset + 7]};
      return value;
    endfunction

    // 功能：按 IBTA 表把 (opcode, segment) 映射为 BTH opcode 低 5 位（RC/UC/UD 共用编号）。
    // 输入/输出及副作用：low 输出编号；纯函数。
    // 失败/边界：组合不存在（如 READ 请求分段、ACK 分段）时返回 0。
    static function bit roce_low_opcode(
      rdma_network_opcode_e opcode,
      rdma_packet_segment_e segment,
      output bit [4:0] low
    );
      low = '0;
      case (opcode)
        RDMA_NET_SEND, RDMA_NET_SEND_WITH_IMM: begin
          case (segment)
            RDMA_SEG_FIRST:  low = 5'h00;
            RDMA_SEG_MIDDLE: low = 5'h01;
            RDMA_SEG_LAST:   low = (opcode == RDMA_NET_SEND) ? 5'h02 : 5'h03;
            default:         low = (opcode == RDMA_NET_SEND) ? 5'h04 : 5'h05;
          endcase
        end
        RDMA_NET_RDMA_WRITE, RDMA_NET_WRITE_WITH_IMM: begin
          case (segment)
            RDMA_SEG_FIRST:  low = 5'h06;
            RDMA_SEG_MIDDLE: low = 5'h07;
            RDMA_SEG_LAST:   low = (opcode == RDMA_NET_RDMA_WRITE) ? 5'h08 : 5'h09;
            default:         low = (opcode == RDMA_NET_RDMA_WRITE) ? 5'h0a : 5'h0b;
          endcase
        end
        RDMA_NET_RDMA_READ_RESP: begin
          case (segment)
            RDMA_SEG_FIRST:  low = 5'h0d;
            RDMA_SEG_MIDDLE: low = 5'h0e;
            RDMA_SEG_LAST:   low = 5'h0f;
            default:         low = 5'h10;
          endcase
        end
        RDMA_NET_RDMA_READ_REQUEST: low = 5'h0c;
        RDMA_NET_ACK, RDMA_NET_NAK: low = 5'h11;
        RDMA_NET_ATOMIC_ACK:        low = 5'h12;
        RDMA_NET_ATOMIC_CMP_SWAP:   low = 5'h13;
        RDMA_NET_ATOMIC_FETCH_ADD:  low = 5'h14;
        default: return 1'b0;
      endcase
      if (segment != RDMA_SEG_ONLY &&
          !(opcode inside {RDMA_NET_SEND, RDMA_NET_SEND_WITH_IMM,
                           RDMA_NET_RDMA_WRITE, RDMA_NET_WRITE_WITH_IMM,
                           RDMA_NET_RDMA_READ_RESP}))
        return 1'b0;
      return 1'b1;
    endfunction

    // 功能：把 RDMA 网络 opcode/segment 映射为 RoCEv2 BTH opcode，并确认 transport 支持该组合。
    // 输入/输出及副作用：value（输入）、opcode（输出）；只做映射，不修改 packet。
    // 失败/边界：UC 只支持 SEND/WRITE，UD 只支持单包 SEND；其它组合返回 UNSUPPORTED_OPCODE。
    static function rdma_status map_roce_opcode(
      rdma_packet value,
      output bit [7:0] opcode
    );
      bit [4:0] low;

      opcode = 8'h04;
      if (value == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "RDMA packet is null");
      if (!roce_low_opcode(value.opcode, value.segment, low))
        return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                 "unsupported network opcode/segment");
      case (value.transport)
        RDMA_TRANSPORT_RC: opcode = {3'b000, low};
        RDMA_TRANSPORT_URC: begin
          if (low > 5'h0b)
            return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                     "unsupported URC network opcode");
          opcode = {3'b001, low};
        end
        RDMA_TRANSPORT_UD: begin
          if (!(low inside {5'h04, 5'h05}))
            return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                     "unsupported UD network opcode");
          opcode = {3'b011, low};
        end
        default:
          return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                   "transport is not RoCEv2");
      endcase
      return rdma_status::success();
    endfunction

    // 功能：根据 rdma_packet 的 opcode 和扩展 header_bytes 填充 RoCEv2 BTH/RETH/DETH/IETH。
    // 输入/输出及副作用：value（输入）、roce（输出）；只更新新建的外部 header，不修改输入 packet。
    // 失败/边界：扩展字段不足时使用安全默认值；不支持的 opcode 由 map_roce_opcode 返回错误。
    static function rdma_status populate_roce_header(
      rdma_packet value,
      output rocev2_bth roce
    );
      rdma_status status;
      bit [7:0] opcode;
      int unsigned extension_offset;
      bit [31:0] aeth_word;

      roce = null;
      status = map_roce_opcode(value, opcode);
      if (status == null || !status.ok())
        return status;
      roce = new();
      if (roce == null)
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "RoCEv2 header allocation failed");
      roce.opcode = rocev2_opcode_e'(opcode);
      roce.dest_qp = value.destination_qpn;
      roce.psn = value.psn;
      roce.pkey = 16'hffff;
      roce.deth_q_key = 32'h8001_0000;
      roce.deth_src_qp = value.source_qpn;
      roce.icrc_enable = 1'b1;
      extension_offset = 0;
      if (roce.has_reth()) begin
        roce.reth_va = read_be64(value.header_bytes, extension_offset);
        roce.reth_r_key = read_be32(value.header_bytes, extension_offset + 8);
        roce.reth_dma_len = read_be32(value.header_bytes, extension_offset + 12);
        if (roce.reth_dma_len == 0)
          roce.reth_dma_len = value.payload.size();
        extension_offset += 16;
      end
      // AETH 位于 RETH 之后、AtomicETH/AtomicAckETH 之前；响应类 opcode 即使用默认
      // syndrome/MSN 也须消费这 4 字节，否则 Atomic ACK 会把 AETH 误当原值高半部。
      if (roce.has_aeth()) begin
        aeth_word = read_be32(value.header_bytes, extension_offset);
        roce.aeth_syndrome = aeth_word[31:24];
        roce.aeth_msn = aeth_word[23:0];
        extension_offset += 4;
      end
      // AtomicETH 顺序：VA(8B)、r_key(4B)、swap/add(8B)、compare(8B)；FetchAdd 的 compare
      // 置零，仍消费完整 28B 以保持后续 ICRC/payload 偏移正确。
      if (roce.has_atomic_eth()) begin
        roce.atomic_va = read_be64(value.header_bytes, extension_offset);
        roce.atomic_r_key = read_be32(value.header_bytes, extension_offset + 8);
        roce.atomic_swap_add = read_be64(value.header_bytes, extension_offset + 12);
        roce.atomic_compare = read_be64(value.header_bytes, extension_offset + 20);
        if (roce.opcode == RC_FETCH_ADD)
          roce.atomic_compare = 64'h0;
        extension_offset += 28;
      end
      // Atomic ACK ETH 只返回 responder 看到的原始 64-bit 数据。
      if (roce.has_atomic_ack_eth()) begin
        roce.atomic_orig_data = read_be64(value.header_bytes, extension_offset);
        extension_offset += 8;
      end
      if (roce.has_immdt()) begin
        roce.imm_data = read_be32(value.header_bytes, extension_offset);
        extension_offset += 4;
      end
      if (roce.has_ieth())
        roce.ieth_r_key = read_be32(value.header_bytes, extension_offset);
      return rdma_status::success();
    endfunction

    // 功能：构造 Ethernet + IPv4 + UDP/TCP + RDMA header 的 net_packet 对象并完成 do_pack。
    // 输入/输出及副作用：value（输入）、net_value（输出）；net_value 为 adapter 新建对象，输入只读。
    // 失败/边界：authority、transport、header 构造或 pack 失败时返回错误，不发布半成品 packet。
    function rdma_status build_packet(
      rdma_packet value,
      output packet net_value
    );
      eth_header eth;
      ipv4_header ip4;
      udp_header udp;
      tcp_header tcp;
      rocev2_bth roce;
      iwarp_header iwarp;
      rdma_status status;
      int unsigned header_bytes;
      int unsigned target_length;

      net_value = null;
      if (value == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "RDMA packet is null");
      net_value = new();
      eth = eth_header::create(48'h0002_0000_0002,
                               48'h0002_0000_0001,
                               ETHERTYPE_IPV4);
      if (!net_value.add_layer(eth))
        return rdma_status::make(RDMA_SC_CODEC_ERROR,
                                 "failed to add Ethernet layer");

      case (value.transport)
        RDMA_TRANSPORT_CUSTOM: begin
          ip4 = ipv4_header::create(32'h0a00_0001, 32'h0a00_0002,
                                    IP_PROTO_TCP, 64);
          tcp = tcp_header::create(16'd5044, 16'd5044, 9'h010);
          iwarp = iwarp_header::create();
          iwarp.queue_number = value.destination_qpn[15:0];
          iwarp.sink_stag = value.destination_qpn;
          case (value.opcode)
            RDMA_NET_SEND:              iwarp.rdmap_opcode = 4'd0;
            RDMA_NET_RDMA_WRITE:        iwarp.rdmap_opcode = 4'd1;
            RDMA_NET_RDMA_READ_REQUEST: iwarp.rdmap_opcode = 4'd2;
            RDMA_NET_RDMA_READ_RESP:    iwarp.rdmap_opcode = 4'd3;
            RDMA_NET_ACK:               iwarp.rdmap_opcode = 4'd4;
            default:
              return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                       "unsupported iWARP network opcode");
          endcase
          if (!net_value.add_layer(ip4) || !net_value.add_layer(tcp) ||
              !net_value.add_layer(iwarp))
            return rdma_status::make(RDMA_SC_CODEC_ERROR,
                                     "failed to add iWARP layers");
        end
        RDMA_TRANSPORT_RC, RDMA_TRANSPORT_UD, RDMA_TRANSPORT_URC: begin
          status = populate_roce_header(value, roce);
          if (status == null || !status.ok())
            return status;
          ip4 = ipv4_header::create(32'h0a00_0001, 32'h0a00_0002,
                                    IP_PROTO_UDP, 64);
          udp = udp_header::create(16'd4791, 16'd4791);
          if (!net_value.add_layer(ip4) || !net_value.add_layer(udp) ||
              !net_value.add_layer(roce))
            return rdma_status::make(RDMA_SC_CODEC_ERROR,
                                     "failed to add RoCEv2 layers");
        end
        default:
          return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                   "transport is unsupported by net_packet adapter");
      endcase

      header_bytes = 0;
      foreach (net_value.layer_stack[i])
        header_bytes += net_value.layer_stack[i].get_header_length();
      target_length = header_bytes + value.payload.size();
      net_value.pkt_len = target_length;
      net_value.payload_mode = PAYLOAD_PATTERN;
      net_value.payload_pattern.delete();
      foreach (value.payload[i])
        net_value.payload_pattern.push_back(value.payload[i]);
      net_value.do_pack();
      // Ethernet 最小帧长为 64B；补齐 bytes 不改变 IP/UDP 声明的有效长度。
      while (net_value.raw_data.size() < 64)
        net_value.raw_data.push_back(8'h00);
      if (net_value.raw_data.size() < header_bytes)
        return rdma_status::make(RDMA_SC_CODEC_ERROR,
                                 "net_packet pack returned short frame");
      return rdma_status::success();
    endfunction

    // 功能：将 rdma_packet 编码为完整 Ethernet frame byte queue，供 sink/PCAP 使用。
    // 输入/输出及副作用：value（输入）、frame_bytes（输出）；只写入新建 byte queue，不推进 PI/CI。
    // 失败/边界：authority 未配置、输入为空或 pack 失败时 frame_bytes 清空并返回错误。
    function rdma_status encode_packet(
      rdma_packet value,
      output byte unsigned frame_bytes[$]
    );
      packet net_value;
      rdma_status status;

      frame_bytes.delete();
      status = validate_authority();
      if (status == null || !status.ok())
        return status;
      status = build_packet(value, net_value);
      if (status == null || !status.ok())
        return status;
      frame_bytes = net_value.raw_data;
      return rdma_status::success();
    endfunction

    // 功能：计算 net_packet raw_data 中 RDMA header 的起始位置和有效网络帧终点。
    // 输入/输出及副作用：net_value（输入）、rdma_offset、frame_end（输出）；只读 layer stack/raw_data。
    // 失败/边界：缺少 IP 层时使用 raw_data.size() 作为保守终点，调用方仍会验证 RDMA layer 存在。
    static function void locate_transport_bounds(
      packet net_value,
      protocol_type_e transport_proto,
      output int unsigned rdma_offset,
      output int unsigned frame_end
    );
      ipv4_header ip4;
      ipv6_header ip6;
      udp_header udp;
      int unsigned offset;
      int unsigned udp_offset;

      rdma_offset = 0;
      frame_end = net_value.raw_data.size();
      offset = 0;
      udp_offset = 0;
      foreach (net_value.layer_stack[i]) begin
        if (net_value.layer_stack[i].proto_type == transport_proto)
          rdma_offset = offset;
        if (net_value.layer_stack[i].proto_type == PROTO_UDP)
          udp_offset = offset;
        offset += net_value.layer_stack[i].get_header_length();
      end
      ip4 = net_value.get_ipv4();
      if (ip4 != null && ip4.total_length != 0 &&
          14 + ip4.total_length < frame_end)
        frame_end = 14 + ip4.total_length;
      ip6 = net_value.get_ipv6();
      if (ip6 != null && ip6.payload_length != 0 &&
          14 + ip6.payload_length + 40 < frame_end)
        frame_end = 14 + ip6.payload_length + 40;
      if (transport_proto == PROTO_ROCEV2) begin
        udp = net_value.get_udp();
        if (udp != null && udp.length >= 8 && udp_offset + udp.length < frame_end)
          frame_end = udp_offset + udp.length;
      end
    endfunction

    // 功能：把 SEND/WRITE 组内偏移（0..5：FIRST、MIDDLE、LAST、LAST_IMM、ONLY、ONLY_IMM）
    //   转成报文分段。
    // 输入/输出及副作用：纯函数。
    // 失败/边界：越界偏移按 ONLY 处理（调用方只传 0..5）。
    static function rdma_packet_segment_e seg_of(bit [4:0] offset);
      case (offset)
        5'd0: return RDMA_SEG_FIRST;
        5'd1: return RDMA_SEG_MIDDLE;
        5'd2, 5'd3: return RDMA_SEG_LAST;
        default: return RDMA_SEG_ONLY;
      endcase
    endfunction

    // 功能：把解析出的 RoCEv2 opcode 投影回 RDMA transport/opcode，并恢复 DETH/PSN 字段。
    // 输入/输出及副作用：roce（输入）、value（输出）；只写入新建 rdma_packet，不修改外部 packet。
    // 失败/边界：未知硬件 opcode 返回 UNSUPPORTED_OPCODE，禁止把未知值伪造为 SEND。
    static function rdma_status decode_roce_header(
      rocev2_bth roce,
      output rdma_packet value
    );
      bit [7:0] full;

      value = rdma_packet::type_id::create("decoded_rocev2");
      if (roce == null)
        return rdma_status::make(RDMA_SC_CODEC_ERROR,
                                 "RoCEv2 header is null");
      value.destination_qpn = roce.dest_qp;
      value.source_qpn = roce.has_deth() ? roce.deth_src_qp : 0;
      value.psn = roce.psn;
      full = roce.opcode;
      case (full[7:5])
        3'b000: value.transport = RDMA_TRANSPORT_RC;
        3'b001: value.transport = RDMA_TRANSPORT_URC;
        3'b011: value.transport = RDMA_TRANSPORT_UD;
        default:
          return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                   "unknown RoCEv2 opcode");
      endcase
      value.segment = RDMA_SEG_ONLY;
      case (full[4:0])
        5'h00, 5'h01, 5'h02, 5'h03, 5'h04, 5'h05: begin
          value.opcode = (full[4:0] inside {5'h03, 5'h05}) ?
                         RDMA_NET_SEND_WITH_IMM : RDMA_NET_SEND;
          value.segment = seg_of(full[4:0] - 5'h00);
        end
        5'h06, 5'h07, 5'h08, 5'h09, 5'h0a, 5'h0b: begin
          value.opcode = (full[4:0] inside {5'h09, 5'h0b}) ?
                         RDMA_NET_WRITE_WITH_IMM : RDMA_NET_RDMA_WRITE;
          value.segment = seg_of(full[4:0] - 5'h06);
        end
        5'h0c: value.opcode = RDMA_NET_RDMA_READ_REQUEST;
        5'h0d, 5'h0e, 5'h0f, 5'h10: begin
          value.opcode = RDMA_NET_RDMA_READ_RESP;
          case (full[4:0])
            5'h0d: value.segment = RDMA_SEG_FIRST;
            5'h0e: value.segment = RDMA_SEG_MIDDLE;
            5'h0f: value.segment = RDMA_SEG_LAST;
            default: value.segment = RDMA_SEG_ONLY;
          endcase
        end
        5'h11: value.opcode = RDMA_NET_ACK;
        5'h12: value.opcode = RDMA_NET_ATOMIC_ACK;
        5'h13: value.opcode = RDMA_NET_ATOMIC_CMP_SWAP;
        5'h14: value.opcode = RDMA_NET_ATOMIC_FETCH_ADD;
        default:
          return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                   "RoCEv2 opcode projection is unsupported");
      endcase
      if ((value.transport == RDMA_TRANSPORT_URC && full[4:0] > 5'h0b) ||
          (value.transport == RDMA_TRANSPORT_UD &&
           !(full[4:0] inside {5'h04, 5'h05})))
        return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                 "RoCEv2 opcode is invalid for its transport");
      return rdma_status::success();
    endfunction

    // 功能：校验 net_packet 各层 verify 结果以及 RoCEv2 ICRC placeholder 的一致性。
    // 输入/输出及副作用：net_value、payload（输入）；verify 可能读取层字段但不改变 packet 语义。
    // 失败/边界：任何硬错误或 ICRC 不一致返回 CODEC_ERROR；warning 不阻塞接收。
    static function rdma_status validate_net_packet(
      packet net_value,
      rocev2_bth roce,
      byte unsigned payload[$]
    );
      string errors[$];
      string warnings[$];
      bit [31:0] saved_icrc;

      if (net_value == null)
        return rdma_status::make(RDMA_SC_CODEC_ERROR,
                                 "net_packet object is null");
      foreach (net_value.layer_stack[i]) begin
        net_value.layer_stack[i].verify(errors, warnings);
      end
      if (errors.size() != 0)
        return rdma_status::make(RDMA_SC_CODEC_ERROR, errors[0]);
      if (roce != null && roce.icrc_enable) begin
        saved_icrc = roce.icrc;
        roce.calc_fields(payload, PROTO_RAW_PAYLOAD);
        if (roce.icrc != saved_icrc) begin
          roce.icrc = saved_icrc;
          return rdma_status::make(RDMA_SC_CODEC_ERROR,
                                   "RoCEv2 ICRC mismatch");
        end
        roce.icrc = saved_icrc;
      end
      return rdma_status::success();
    endfunction

    // 功能：解析完整 Ethernet frame，提取 RDMA header/payload 并生成 detached rdma_packet。
    // 输入/输出及副作用：frame_bytes（输入）、value（输出）；只创建本地 parser 对象，不取得 frame_bytes 所有权。
    // 失败/边界：长度不足、协议层缺失、校验失败或未知 opcode 均返回明确 codec 错误。
    function rdma_status decode_packet(
      byte unsigned frame_bytes[$],
      output rdma_packet value
    );
      packet net_value;
      rocev2_bth roce;
      iwarp_header iwarp;
      rdma_status status;
      int unsigned rdma_offset;
      int unsigned frame_end;
      int unsigned payload_offset;
      int unsigned payload_end;
      int unsigned iwarp_offset;
      int unsigned index;

      value = null;
      status = validate_authority();
      if (status == null || !status.ok())
        return status;
      if (frame_bytes.size() < 14)
        return rdma_status::make(RDMA_SC_CODEC_ERROR,
                                 "Ethernet frame is too short");
      net_value = new();
      net_value.unpack(frame_bytes);
      roce = net_value.get_rocev2();
      iwarp = net_value.get_iwarp();
      if (roce == null && iwarp == null)
        return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                 "packet does not contain RoCEv2 or iWARP");
      if (roce != null) begin
        locate_transport_bounds(net_value, PROTO_ROCEV2,
                                rdma_offset, frame_end);
        payload_offset = rdma_offset + roce.get_header_length();
        // locate_transport_bounds 已用 UDP length/IP total_length 去掉以太网补齐字节。
        payload_end = frame_end;
        if (payload_end < payload_offset || payload_end > frame_bytes.size())
          return rdma_status::make(RDMA_SC_CODEC_ERROR,
                                   "RoCEv2 payload bounds are invalid");
        value = null;
        for (index = payload_offset; index < payload_end; index++) begin
          if (value == null)
            value = rdma_packet::type_id::create("decoded_rocev2");
        end
        status = decode_roce_header(roce, value);
        if (status == null || !status.ok())
          return status;
        // header_bytes 与 encode_packet 输入契约一致：只存 BTH 之后的扩展字段，
        // 不含 BTH、DETH（encode 由 source_qpn 等字段生成）和尾部 ICRC，使 decode→encode 可直接复用。
        value.header_bytes.delete();
        frame_end = payload_offset;
        if (roce.icrc_enable && frame_end >= 4)
          frame_end -= 4;
        for (index = rdma_offset + 12 + (roce.has_deth() ? 8 : 0); index < frame_end; index++)
          value.header_bytes.push_back(frame_bytes[index]);
        value.payload.delete();
        for (index = payload_offset; index < payload_end; index++)
          value.payload.push_back(frame_bytes[index]);
        status = validate_net_packet(net_value, roce, value.payload);
        return status;
      end

      locate_transport_bounds(net_value, PROTO_IWARP,
                              iwarp_offset, frame_end);
      payload_offset = iwarp_offset + iwarp.get_header_length();
      payload_end = frame_end;
      if (payload_end < payload_offset || payload_end > frame_bytes.size())
        return rdma_status::make(RDMA_SC_CODEC_ERROR,
                                 "iWARP payload bounds are invalid");
      value = rdma_packet::type_id::create("decoded_iwarp");
      value.transport = RDMA_TRANSPORT_CUSTOM;
      value.destination_qpn = iwarp.queue_number;
      value.source_qpn = 0;
      value.psn = 0;
      case (iwarp.rdmap_opcode)
        4'd0: value.opcode = RDMA_NET_SEND;
        4'd1: value.opcode = RDMA_NET_RDMA_WRITE;
        4'd2: value.opcode = RDMA_NET_RDMA_READ_REQUEST;
        4'd3: value.opcode = RDMA_NET_RDMA_READ_RESP;
        4'd4: value.opcode = RDMA_NET_ACK;
        default:
          return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                   "unknown iWARP RDMAP opcode");
      endcase
      value.header_bytes.delete();
      for (index = iwarp_offset + iwarp.get_header_length();
           index < payload_offset; index++)
        value.header_bytes.push_back(frame_bytes[index]);
      value.payload.delete();
      for (index = payload_offset; index < payload_end; index++)
        value.payload.push_back(frame_bytes[index]);
      status = validate_net_packet(net_value, null, value.payload);
      return status;
    endfunction

    // 功能：根据 response policy 和一次性 fault 计算本次发送的 drop/corrupt/delay 行为。
    // 输入/输出及副作用：drop、corrupt、delay、fault_index、fault_mask（输出）；读取策略并消费 pending_fault。
    // 失败/边界：周期为零表示关闭策略；fault_index 越界时发送路径忽略 corruption 而不越界写入。
    function void select_send_fault(
      output bit drop,
      output bit corrupt,
      output longint unsigned delay,
      output int unsigned fault_index,
      output byte unsigned fault_mask
    );
      drop = 1'b0;
      corrupt = 1'b0;
      delay = 0;
      fault_index = 0;
      fault_mask = 8'h01;
      if (response_policy != null) begin
        if (response_policy.drop_every_n != 0 &&
            (send_sequence % response_policy.drop_every_n) == 0)
          drop = 1'b1;
        if (response_policy.corrupt_every_n != 0 &&
            (send_sequence % response_policy.corrupt_every_n) == 0)
          corrupt = 1'b1;
        delay = response_policy.delay_cycles;
      end
      if (pending_fault != null) begin
        if (pending_fault.kind == RDMA_FAULT_PACKET_DROP ||
            pending_fault.drop_packet)
          drop = 1'b1;
        if (pending_fault.corrupt_byte)
          corrupt = 1'b1;
        if (pending_fault.delay_cycles != 0)
          delay = pending_fault.delay_cycles;
        fault_index = pending_fault.corrupt_byte_index;
        fault_mask = pending_fault.corrupt_xor_mask;
        pending_fault = null;
      end
    endfunction

    // 功能：编码、应用发送故障策略、提交 sink 并通知 observer。
    // 输入/输出及副作用：value（输入）、status（输出）；更新发送统计，绝不推进 RDMA PI/CI。
    // 失败/边界：authority/sink/pack/fault 失败时不提交半包；drop 返回 OK 但增加 dropped_count。
    virtual task send_packet(rdma_packet packet, output rdma_status status);
      rdma_net_packet_adapter_pkg::packet net_value;
      rdma_packet observer_value;
      bit drop;
      bit corrupt;
      longint unsigned delay;
      int unsigned fault_index;
      byte unsigned fault_mask;

      status = validate_authority();
      if (status == null || !status.ok())
        return;
      if (sink == null) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "net_packet sink is not configured");
        return;
      end
      send_sequence++;
      status = build_packet(packet, net_value);
      if (status == null || !status.ok())
        return;
      select_send_fault(drop, corrupt, delay, fault_index, fault_mask);
      if (delay != 0) begin
        #(delay);
        delayed_cycles += delay;
      end
      if (drop) begin
        dropped_count++;
        status = rdma_status::success("packet dropped by injected policy");
        return;
      end
      if (corrupt && net_value.raw_data.size() != 0) begin
        if (fault_index >= net_value.raw_data.size())
          fault_index = 0;
        net_value.raw_data[fault_index] ^= fault_mask;
        corrupted_count++;
      end
      last_sent_packet = net_value;
      sink.send(net_value, status);
      if (status == null || !status.ok())
        return;
      observer_value = rdma_packet::type_id::create("sent_observer_packet");
      if (!rdma_deep_copy#(rdma_packet)::try_of(packet, observer_value)) begin
        status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "sent observer packet clone failed");
        return;
      end
      foreach (observers[i]) begin
        if (observers[i] != null)
          observers[i].write(observer_value);
      end
      status = rdma_status::success();
    endtask

    // 功能：从 sink 取 packet、解析并通知 observer，返回 detached RDMA 语义快照。
    // 输入/输出及副作用：value、status（输出）；更新接收统计，不修改 SQ/CQ/host-mem 状态。
    // 失败/边界：sink 空、队列空、协议未知或 checksum/ICRC 失败时返回错误且 value 为空。
    virtual task receive_packet(output rdma_packet packet,
                                output rdma_status status);
      rdma_net_packet_adapter_pkg::packet net_value;
      rdma_packet observer_value;
      uvm_object cloned_object;

      packet = null;
      status = validate_authority();
      if (status == null || !status.ok())
        return;
      if (sink == null) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "net_packet sink is not configured");
        return;
      end
      receive_sequence++;
      sink.receive(net_value, status);
      if (status == null || !status.ok())
        return;
      status = decode_packet(net_value.raw_data, packet);
      if (status == null || !status.ok()) begin
        packet = null;
        return;
      end
      cloned_object = packet.clone();
      if (cloned_object != null && $cast(observer_value, cloned_object)) begin
        foreach (observers[i]) begin
          if (observers[i] != null)
            observers[i].write(observer_value);
        end
      end
      status = rdma_status::success();
    endtask
  endclass
endpackage
