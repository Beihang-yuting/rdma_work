// 目录：外部组件层 adapters/net_packet/rdma_netpkt_pkg.sv。
// 职责：直接使用外部 net_packet 做 RoCEv2 帧编解码：设备内部的 rdma_packet（RDMA 语义字段）编码为
//   Ethernet + IPv4 + UDP + BTH/扩展头 + 负载 + ICRC 帧，并把帧解析回 rdma_packet（校验各层与 ICRC）。
//   RC/UD 按 IBTA opcode；URC 用 0b110 前缀，扩展头随负载前缀原样携带（net_packet 不识别 URC 扩展头）。
// 依赖：外部 net_packet（packet.sv 及协议头，经 NET_PACKET_ROOT）、rdma_types_pkg、rdma_model_pkg。
// 所有权：codec 只持有帧地址配置；编解码产生新对象，不修改输入。
// 生命周期：随使用方存在。

package rdma_netpkt_pkg;
  // 上游 packet/header 声明在编译单元作用域，VCS 不允许 package 内 forward typedef 绑定外部 $unit
  // 类；故在本 package 内 include packet.sv，使协议类型同处一个作用域（不复制源码）。
  `include "packet.sv"
  import uvm_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  `include "uvm_macros.svh"

  class rdma_netpkt_codec extends uvm_object;
    `rdma_object_utils(rdma_netpkt_codec)

    // 帧的以太网/IPv4 地址（本端为源）；缺省为 loopback 链路的固定值，与真实对端（如 Soft-RoCE）互通时
    //   按链路配置。
    bit [47:0] src_mac;
    bit [47:0] dst_mac;
    bit [31:0] src_ip;
    bit [31:0] dst_ip;

    // 功能：构造，地址取缺省值。
    // 输入/输出及副作用：name 为 UVM 名。
    // 失败/边界：无。
    function new(string name = "rdma_netpkt_codec");
      super.new(name);
      src_mac = 48'h0002_0000_0001;
      dst_mac = 48'h0002_0000_0002;
      src_ip = 32'h0a00_0001;
      dst_ip = 32'h0a00_0002;
    endfunction

    // 功能：把 rdma_packet 编码为完整 Ethernet 帧（不足 64B 补零）。
    // 输入/输出及副作用：frame 输出新字节队列。
    // 失败/边界：opcode/分段组合不被该传输支持或 pack 失败时返回错误，frame 为空。
    function rdma_status encode(rdma_packet value, output byte unsigned frame[$]);
      packet net_value;
      rocev2_bth roce;
      int unsigned header_bytes;
      rdma_status status;

      frame.delete();
      if (value == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "RDMA packet is null");
      status = populate_roce_header(value, roce);
      if (!status.ok())
        return status;
      net_value = new();
      if (!net_value.add_layer(eth_header::create(dst_mac, src_mac, ETHERTYPE_IPV4)) ||
          !net_value.add_layer(ipv4_header::create(src_ip, dst_ip, IP_PROTO_UDP, 64)) ||
          !net_value.add_layer(udp_header::create(16'd4791, 16'd4791)) ||
          !net_value.add_layer(roce))
        return rdma_status::make(RDMA_SC_CODEC_ERROR, "failed to add RoCEv2 layers");
      header_bytes = 0;
      foreach (net_value.layer_stack[i])
        header_bytes += net_value.layer_stack[i].get_header_length();
      // ICRC 是负载之后的尾部；pad 由 net_packet 按 PadCnt 补齐。
      net_value.payload_mode = PAYLOAD_PATTERN;
      net_value.payload_pattern.delete();
      if (value.transport == RDMA_TRANSPORT_URC)
        foreach (value.header_bytes[i])
          net_value.payload_pattern.push_back(value.header_bytes[i]);
      foreach (value.payload[i])
        net_value.payload_pattern.push_back(value.payload[i]);
      net_value.pkt_len = header_bytes + net_value.get_all_trailers_length() +
                          net_value.payload_pattern.size();
      net_value.do_pack();
      // Ethernet 最小帧长为 64B；补齐字节不改变 IP/UDP 声明的有效长度。
      while (net_value.raw_data.size() < 64)
        net_value.raw_data.push_back(8'h00);
      if (net_value.raw_data.size() < header_bytes)
        return rdma_status::make(RDMA_SC_CODEC_ERROR, "net_packet pack returned a short frame");
      frame = net_value.raw_data;
      return rdma_status::success();
    endfunction

    // 功能：解析 Ethernet 帧为 rdma_packet：header_bytes 为 BTH（与 DETH）之后的扩展头，payload 去掉
    //   pad 与 ICRC；校验 net_packet 各层与 ICRC。
    // 输入/输出及副作用：value 输出新对象。
    // 失败/边界：长度不足、不是 RoCEv2、边界非法、校验失败或未知 opcode 返回错误，value 为 null。
    function rdma_status decode(byte unsigned frame[$], output rdma_packet value);
      packet net_value;
      rocev2_bth roce;
      rdma_status status;
      int unsigned rdma_offset;
      int unsigned payload_offset;
      int unsigned payload_end;
      string errors[$];
      string warnings[$];

      value = null;
      if (frame.size() < 14)
        return rdma_status::make(RDMA_SC_CODEC_ERROR, "Ethernet frame is too short");
      net_value = new();
      net_value.unpack(frame);
      roce = net_value.get_rocev2();
      if (roce == null)
        return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE, "frame does not carry RoCEv2");
      locate_bounds(net_value, rdma_offset, payload_end);
      payload_offset = rdma_offset + roce.get_header_length();
      // 有效帧之后依次是 PadCnt 个 pad 字节与 ICRC 尾部。
      payload_end -= roce.get_trailer_length();
      if (payload_end >= payload_offset + roce.pad_count)
        payload_end -= roce.pad_count;
      if (payload_end < payload_offset || payload_end > frame.size())
        return rdma_status::make(RDMA_SC_CODEC_ERROR, "RoCEv2 payload bounds are invalid");
      foreach (net_value.layer_stack[i])
        net_value.layer_stack[i].verify(errors, warnings);
      if (errors.size() != 0)
        return rdma_status::make(RDMA_SC_CODEC_ERROR, errors[0]);
      if (!net_value.verify_rocev2_icrc())
        return rdma_status::make(RDMA_SC_CODEC_ERROR, "RoCEv2 ICRC mismatch");
      status = decode_roce_header(roce, value);
      if (!status.ok()) begin
        value = null;
        return status;
      end
      // header_bytes 与 encode 输入一致：BTH、DETH 之后的扩展字段（DETH 由 source_qpn 等字段生成）。
      for (int unsigned i = rdma_offset + 12 + (roce.has_deth() ? 8 : 0); i < payload_offset; i++)
        value.header_bytes.push_back(frame[i]);
      for (int unsigned i = payload_offset; i < payload_end; i++)
        value.payload.push_back(frame[i]);
      if (value.transport == RDMA_TRANSPORT_URC)
        status = split_urc_headers(value);
      if (!status.ok())
        value = null;
      return status;
    endfunction

    // 功能：BTH 在帧中的偏移与有效帧终点（按 IPv4 total_length/UDP length 去掉以太网补齐）。
    // 输入/输出及副作用：纯查询。
    // 失败/边界：缺长度字段时终点为帧长。
    protected static function void locate_bounds(packet net_value, output int unsigned rdma_offset,
                                                 output int unsigned frame_end);
      ipv4_header ip4;
      udp_header udp;
      int unsigned offset;
      int unsigned udp_offset;

      rdma_offset = 0;
      udp_offset = 0;
      offset = 0;
      frame_end = net_value.raw_data.size();
      foreach (net_value.layer_stack[i]) begin
        if (net_value.layer_stack[i].proto_type == PROTO_ROCEV2)
          rdma_offset = offset;
        if (net_value.layer_stack[i].proto_type == PROTO_UDP)
          udp_offset = offset;
        offset += net_value.layer_stack[i].get_header_length();
      end
      ip4 = net_value.get_ipv4();
      if (ip4 != null && ip4.total_length != 0 && 14 + ip4.total_length < frame_end)
        frame_end = 14 + ip4.total_length;
      udp = net_value.get_udp();
      if (udp != null && udp.length >= 8 && udp_offset + udp.length < frame_end)
        frame_end = udp_offset + udp.length;
    endfunction

    // 功能：大端读 32 位扩展头字段。
    // 输入/输出及副作用：纯函数。
    // 失败/边界：长度不足返回 0。
    protected static function bit [31:0] be32(byte unsigned bytes[$], int unsigned offset);
      if (offset + 4 > bytes.size())
        return '0;
      return {bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]};
    endfunction

    // 功能：大端读 64 位扩展头字段。
    // 输入/输出及副作用：纯函数。
    // 失败/边界：长度不足的部分为 0。
    protected static function bit [63:0] be64(byte unsigned bytes[$], int unsigned offset);
      return {be32(bytes, offset), be32(bytes, offset + 4)};
    endfunction

    // 功能：按 IBTA 表把 (opcode, segment) 映射为 BTH opcode 低 5 位（RC/UD 共用编号）。
    // 输入/输出及副作用：low 输出；纯函数。
    // 失败/边界：组合不存在（如 READ 请求分段、ACK 分段）返回 0。
    protected static function bit low_opcode(rdma_network_opcode_e opcode,
                                             rdma_packet_segment_e segment, output bit [4:0] low);
      low = '0;
      case (opcode)
        RDMA_NET_SEND, RDMA_NET_SEND_WITH_IMM:
          case (segment)
            RDMA_SEG_FIRST:  low = 5'h00;
            RDMA_SEG_MIDDLE: low = 5'h01;
            RDMA_SEG_LAST:   low = opcode == RDMA_NET_SEND ? 5'h02 : 5'h03;
            default:         low = opcode == RDMA_NET_SEND ? 5'h04 : 5'h05;
          endcase
        RDMA_NET_RDMA_WRITE, RDMA_NET_WRITE_WITH_IMM:
          case (segment)
            RDMA_SEG_FIRST:  low = 5'h06;
            RDMA_SEG_MIDDLE: low = 5'h07;
            RDMA_SEG_LAST:   low = opcode == RDMA_NET_RDMA_WRITE ? 5'h08 : 5'h09;
            default:         low = opcode == RDMA_NET_RDMA_WRITE ? 5'h0a : 5'h0b;
          endcase
        RDMA_NET_RDMA_READ_RESP:
          case (segment)
            RDMA_SEG_FIRST:  low = 5'h0d;
            RDMA_SEG_MIDDLE: low = 5'h0e;
            RDMA_SEG_LAST:   low = 5'h0f;
            default:         low = 5'h10;
          endcase
        RDMA_NET_RDMA_READ_REQUEST: low = 5'h0c;
        RDMA_NET_ACK, RDMA_NET_NAK: low = 5'h11;
        RDMA_NET_ATOMIC_ACK:        low = 5'h12;
        RDMA_NET_ATOMIC_CMP_SWAP:   low = 5'h13;
        RDMA_NET_ATOMIC_FETCH_ADD:  low = 5'h14;
        default: return 1'b0;
      endcase
      return segment == RDMA_SEG_ONLY ||
             opcode inside {RDMA_NET_SEND, RDMA_NET_SEND_WITH_IMM, RDMA_NET_RDMA_WRITE,
                            RDMA_NET_WRITE_WITH_IMM, RDMA_NET_RDMA_READ_RESP};
    endfunction

    // 功能：rdma_packet → 完整 BTH opcode：RC 前缀 000、UD 011（仅 SEND ONLY）、URC 110（READ 请求
    //   可分 FIRST/MIDDLE/LAST 0x0d-0x0f，每个请求包对应一个 READ 响应 ONLY）。
    // 输入/输出及副作用：opcode 输出；纯函数。
    // 失败/边界：组合不被该传输支持返回 UNSUPPORTED_OPCODE。
    protected static function rdma_status map_opcode(rdma_packet value, output bit [7:0] opcode);
      bit [4:0] low;

      opcode = '0;
      if (value.transport == RDMA_TRANSPORT_URC && value.opcode == RDMA_NET_RDMA_READ_REQUEST)
        low = value.segment == RDMA_SEG_FIRST ? 5'h0d : value.segment == RDMA_SEG_MIDDLE ? 5'h0e :
              value.segment == RDMA_SEG_LAST ? 5'h0f : 5'h0c;
      else if (!low_opcode(value.opcode, value.segment, low))
        return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE, "unsupported network opcode/segment");
      case (value.transport)
        RDMA_TRANSPORT_RC: opcode = {3'b000, low};
        RDMA_TRANSPORT_URC: begin
          if (value.opcode == RDMA_NET_RDMA_READ_RESP && value.segment != RDMA_SEG_ONLY)
            return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                     "URC READ data is one packet per request");
          opcode = {3'b110, low};
        end
        RDMA_TRANSPORT_UD: begin
          if (!(low inside {5'h04, 5'h05}))
            return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE, "unsupported UD network opcode");
          opcode = {3'b011, low};
        end
        default:
          return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE, "transport is not RoCEv2");
      endcase
      return rdma_status::success();
    endfunction

    // 功能：由 rdma_packet 填 BTH/DETH 与扩展头（header_bytes 依次为 RETH、AETH、AtomicETH、
    //   AtomicAckETH、ImmDt、IETH 中该 opcode 带的部分）。
    // 输入/输出及副作用：roce 输出新对象。
    // 失败/边界：opcode 不支持时返回 map_opcode 的错误。
    protected static function rdma_status populate_roce_header(rdma_packet value,
                                                               output rocev2_bth roce);
      bit [7:0] opcode;
      bit [31:0] aeth;
      int unsigned at;
      rdma_status status;

      roce = null;
      status = map_opcode(value, opcode);
      if (!status.ok())
        return status;
      roce = new();
      roce.opcode = rocev2_opcode_e'(opcode);
      roce.dest_qp = value.destination_qpn;
      roce.psn = value.psn;
      roce.ack_req = value.ack_req;
      roce.pkey = 16'hffff;
      roce.deth_q_key = value.deth_qkey;
      roce.deth_src_qp = value.source_qpn;
      roce.icrc_enable = 1'b1;
      at = 0;
      if (roce.has_reth()) begin
        roce.reth_va = be64(value.header_bytes, at);
        roce.reth_r_key = be32(value.header_bytes, at + 8);
        roce.reth_dma_len = be32(value.header_bytes, at + 12);
        if (roce.reth_dma_len == 0)
          roce.reth_dma_len = value.payload.size();
        at += 16;
      end
      // 响应类 opcode 的 AETH 即使取缺省值也占 4 字节，否则 ATOMIC ACK 会把 AETH 当作原值高半部。
      if (roce.has_aeth()) begin
        aeth = be32(value.header_bytes, at);
        roce.aeth_syndrome = aeth[31:24];
        roce.aeth_msn = aeth[23:0];
        at += 4;
      end
      // AtomicETH：VA(8)、R_Key(4)、swap/add(8)、compare(8)；FETCH_ADD 的 compare 为 0。
      if (roce.has_atomic_eth()) begin
        roce.atomic_va = be64(value.header_bytes, at);
        roce.atomic_r_key = be32(value.header_bytes, at + 8);
        roce.atomic_swap_add = be64(value.header_bytes, at + 12);
        roce.atomic_compare = roce.opcode == RC_FETCH_ADD ? 64'h0 :
                                                            be64(value.header_bytes, at + 20);
        at += 28;
      end
      if (roce.has_atomic_ack_eth()) begin
        roce.atomic_orig_data = be64(value.header_bytes, at);
        at += 8;
      end
      if (roce.has_immdt()) begin
        roce.imm_data = be32(value.header_bytes, at);
        at += 4;
      end
      if (roce.has_ieth())
        roce.ieth_r_key = be32(value.header_bytes, at);
      return rdma_status::success();
    endfunction

    // 功能：SEND/WRITE 组内偏移（0..5：FIRST、MIDDLE、LAST、LAST_IMM、ONLY、ONLY_IMM）→ 分段。
    // 输入/输出及副作用：纯函数。
    // 失败/边界：越界偏移按 ONLY。
    protected static function rdma_packet_segment_e seg_of(bit [4:0] offset);
      case (offset)
        5'd0: return RDMA_SEG_FIRST;
        5'd1: return RDMA_SEG_MIDDLE;
        5'd2, 5'd3: return RDMA_SEG_LAST;
        default: return RDMA_SEG_ONLY;
      endcase
    endfunction

    // 功能：BTH/DETH → rdma_packet 的传输、opcode、分段、QPN、PSN、Q_Key。
    // 输入/输出及副作用：value 输出新对象。
    // 失败/边界：未知前缀或 opcode、UD 非 SEND ONLY 返回 UNSUPPORTED_OPCODE。
    protected static function rdma_status decode_roce_header(rocev2_bth roce,
                                                             output rdma_packet value);
      bit [7:0] full;

      value = rdma_packet::type_id::create("decoded_rocev2");
      value.destination_qpn = roce.dest_qp;
      value.source_qpn = roce.has_deth() ? roce.deth_src_qp : 0;
      value.deth_qkey = roce.has_deth() ? roce.deth_q_key : 0;
      value.psn = roce.psn;
      value.ack_req = roce.ack_req;
      full = roce.opcode;
      case (full[7:5])
        3'b000: value.transport = RDMA_TRANSPORT_RC;
        3'b110: value.transport = RDMA_TRANSPORT_URC;
        3'b011: value.transport = RDMA_TRANSPORT_UD;
        default: return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE, "unknown RoCEv2 opcode");
      endcase
      value.segment = RDMA_SEG_ONLY;
      case (full[4:0])
        5'h00, 5'h01, 5'h02, 5'h03, 5'h04, 5'h05: begin
          value.opcode = full[4:0] inside {5'h03, 5'h05} ? RDMA_NET_SEND_WITH_IMM : RDMA_NET_SEND;
          value.segment = seg_of(full[4:0]);
        end
        5'h06, 5'h07, 5'h08, 5'h09, 5'h0a, 5'h0b: begin
          value.opcode = full[4:0] inside {5'h09, 5'h0b} ? RDMA_NET_WRITE_WITH_IMM :
                                                           RDMA_NET_RDMA_WRITE;
          value.segment = seg_of(full[4:0] - 5'h06);
        end
        5'h0c: value.opcode = RDMA_NET_RDMA_READ_REQUEST;
        5'h0d, 5'h0e, 5'h0f: begin
          // RC：READ 响应 FIRST/MIDDLE/LAST；URC：READ 请求 FIRST/MIDDLE/LAST。
          value.opcode = value.transport == RDMA_TRANSPORT_URC ? RDMA_NET_RDMA_READ_REQUEST :
                                                                 RDMA_NET_RDMA_READ_RESP;
          value.segment = full[4:0] == 5'h0d ? RDMA_SEG_FIRST :
                          full[4:0] == 5'h0e ? RDMA_SEG_MIDDLE : RDMA_SEG_LAST;
        end
        5'h10: value.opcode = RDMA_NET_RDMA_READ_RESP;
        5'h11: value.opcode = RDMA_NET_ACK;
        5'h12: value.opcode = RDMA_NET_ATOMIC_ACK;
        5'h13: value.opcode = RDMA_NET_ATOMIC_CMP_SWAP;
        5'h14: value.opcode = RDMA_NET_ATOMIC_FETCH_ADD;
        default:
          return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE, "RoCEv2 opcode is unsupported");
      endcase
      if (value.transport == RDMA_TRANSPORT_UD && !(full[4:0] inside {5'h04, 5'h05}))
        return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                 "RoCEv2 opcode is invalid for its transport");
      return rdma_status::success();
    endfunction

    // 功能：URC：按 opcode/分段的扩展头长度把负载前缀切回 header_bytes。
    // 输入/输出及副作用：修改 value.header_bytes/payload。
    // 失败/边界：负载短于扩展头返回 CODEC_ERROR。
    protected static function rdma_status split_urc_headers(rdma_packet value);
      int unsigned n;

      n = value.header_length();
      if (value.payload.size() < n)
        return rdma_status::make(RDMA_SC_CODEC_ERROR, "URC extension headers are truncated");
      value.header_bytes.delete();
      repeat (n)
        value.header_bytes.push_back(value.payload.pop_front());
      return rdma_status::success();
    endfunction
  endclass
endpackage
