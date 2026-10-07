// 目录：验证组件层 tb/rdma_proto_checker.sv。
// 层：验证组件。
// 职责：IBTA 协议检查：rdma_proto_checker 订阅链路观测（tx：仿真 NIC 发出的报文，即被测对象；rx：交付的
//   报文，含远端 rxe 发来的与 netpkt 链路的帧），分发给规则类；每组规则一个类，可按规则名列入
//   cfg.deviations 降级为 info。
//   - rdma_rule_frame：RoCEv2 帧（netpkt）：以太类型/IPv4/UDP 4791/长度、BTH TVer 0、P_Key 0xFFFF、pad、ICRC。
//   - rdma_rule_psn：请求 PSN 不跳号（重传可回退），READ 请求占用响应包数个 PSN；READ 响应在请求范围内。
//   - rdma_rule_ack：RC/URC SEND/WRITE 末包 AckReq；ACK/NAK 的 PSN 不超过已收请求；MSN 不回退；syndrome 合法。
//   - rdma_rule_rnr：RNR NAK 的定时器编码为响应方 QP 的 min_rnr（URC 为 URC_RNR_CODE）；请求方不早于
//     定时器重发。
//   - rdma_rule_state：发送 QP 存在且状态允许（请求：RTS/SQD/ERR；响应：RTR 起）；目的 QP 存在。
//   - rdma_rule_ud：UD 单包、载荷 ≤ MTU（Q_Key 取自 WR，不符时接收端丢弃由 scoreboard 判定）。
// 依赖：rdma_env（资源库、配置）、rdma_link_obs、net_packet ICRC 计算。
// 所有权：规则状态归各规则对象。
// 生命周期：env 创建；仿真期间常驻。

typedef class rdma_proto_checker;

// 规则基类：on_tx/on_rx 检查观测，fail 报告违例（偏差清单内降级）。
virtual class rdma_proto_rule extends uvm_object;
  rdma_proto_checker chk;
  int unsigned checked;

  // 功能：构造。
  // 输入/输出及副作用：name 为规则名（偏差清单按它匹配）。
  // 失败/边界：无。
  function new(string name = "rdma_proto_rule");
    super.new(name);
  endfunction

  // 功能：检查仿真 NIC 发出的报文。
  // 输入/输出及副作用：由规则决定。
  // 失败/边界：无。
  virtual function void on_tx(rdma_link_obs o);
  endfunction

  // 功能：检查交付的报文。
  // 输入/输出及副作用：由规则决定。
  // 失败/边界：无。
  virtual function void on_rx(rdma_link_obs o);
  endfunction

  // 功能：报告违例。
  // 输入/输出及副作用：见 rdma_proto_checker.violation。
  // 失败/边界：无。
  function void fail(rdma_link_obs o, string msg);
    chk.violation(get_name(), $sformatf("f%0d->f%0d %s psn %06h: %s", o.src, o.dst,
                  o.pkt.opcode.name(), o.pkt.psn, msg));
  endfunction
endclass

`uvm_analysis_imp_decl(_tx)
`uvm_analysis_imp_decl(_rx)

class rdma_proto_checker extends uvm_component;
  `uvm_component_utils(rdma_proto_checker)

  rdma_env env;
  uvm_analysis_imp_tx #(rdma_link_obs, rdma_proto_checker) tx_export;
  uvm_analysis_imp_rx #(rdma_link_obs, rdma_proto_checker) rx_export;
  rdma_proto_rule rules[$];
  int unsigned violations[string];

  // 功能：构造。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_proto_checker", uvm_component parent = null);
    super.new(name, parent);
    tx_export = new("tx_export", this);
    rx_export = new("rx_export", this);
  endfunction

  // 功能：按名字创建全部规则（factory 可替换单条规则）。
  // 输入/输出及副作用：填充 rules。
  // 失败/边界：无。
  function void build_phase(uvm_phase phase);
    string names[] = '{"rdma_rule_frame", "rdma_rule_psn", "rdma_rule_ack", "rdma_rule_rnr",
                       "rdma_rule_state", "rdma_rule_ud"};
    rdma_proto_rule r;

    super.build_phase(phase);
    foreach (names[i]) begin
      void'($cast(r, uvm_factory::get().create_object_by_name(names[i], "", names[i])));
      r.chk = this;
      rules.push_back(r);
    end
  endfunction

  // 功能：仿真 NIC 发出的报文交给各规则（远端 Function 发出的不是被测对象）。
  // 输入/输出及副作用：更新规则状态。
  // 失败/边界：无。
  function void write_tx(rdma_link_obs o);
    if (env.res.funcs[o.src].remote)
      return;
    foreach (rules[i])
      rules[i].on_tx(o);
  endfunction

  // 功能：交付的报文交给各规则。
  // 输入/输出及副作用：更新规则状态。
  // 失败/边界：无。
  function void write_rx(rdma_link_obs o);
    foreach (rules[i])
      rules[i].on_rx(o);
  endfunction

  // 功能：违例：偏差清单内的规则报 info，否则 UVM_ERROR。
  // 输入/输出及副作用：计数。
  // 失败/边界：无。
  function void violation(string rule, string msg);
    violations[rule]++;
    if (env.cfg.deviates(rule))
      `uvm_info("RDMA_PROTO", {"deviation ", rule, ": ", msg}, UVM_MEDIUM)
    else
      `uvm_error("RDMA_PROTO", {rule, ": ", msg})
  endfunction

  // 功能：各规则检查次数与违例数。
  // 输入/输出及副作用：报告。
  // 失败/边界：无。
  function void report_phase(uvm_phase phase);
    string line;

    line = "";
    foreach (rules[i])
      line = {line, $sformatf(" %s=%0d/%0d", rules[i].get_name(), rules[i].checked,
                              violations.exists(rules[i].get_name()) ?
                              violations[rules[i].get_name()] : 0)};
    `uvm_info("RDMA_PROTO", {"checked/violations:", line}, UVM_LOW)
  endfunction

  // 功能：发送方 QP（远端 rxe 的 RC 报文不带源 QPN，取不到）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：不存在返回 null。
  function rdma_res_qp sender(rdma_link_obs o);
    return env.res.qp(o.src, o.pkt.source_qpn);
  endfunction

  // 功能：目的 QP。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：不存在返回 null。
  function rdma_res_qp receiver(rdma_link_obs o);
    return env.res.qp(o.dst, o.pkt.destination_qpn);
  endfunction

  // 功能：是否为请求报文。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  static function bit request(rdma_packet p);
    return p.opcode inside {RDMA_NET_SEND, RDMA_NET_SEND_WITH_IMM, RDMA_NET_RDMA_WRITE,
                            RDMA_NET_WRITE_WITH_IMM, RDMA_NET_RDMA_READ_REQUEST,
                            RDMA_NET_ATOMIC_CMP_SWAP, RDMA_NET_ATOMIC_FETCH_ADD};
  endfunction

  // 功能：24 位 PSN 空间中 a 是否在 b 之后。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  static function bit after(bit [23:0] a, bit [23:0] b);
    bit [23:0] d;

    d = a - b;
    return d != 0 && d < 24'h80_0000;
  endfunction

  // 功能：请求占用的 PSN 数（READ 为响应包数）。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：mtu 为 0 按 1 个包。
  static function int unsigned span(rdma_packet p, int unsigned mtu);
    if (p.opcode != RDMA_NET_RDMA_READ_REQUEST || mtu == 0 || p.reth_len == 0)
      return 1;
    return (p.reth_len + mtu - 1) / mtu;
  endfunction

  // 功能：流键：Function 下标/QPN/资源代数（QPN 复用的新 QP 是新流）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：资源库中没有该 QP 时代数取 0。
  function string key(int unsigned f, int unsigned qpn);
    rdma_res_qp q;

    q = env.res.qp(f, qpn);
    return $sformatf("%0d/%0d/%0d", f, qpn, q == null ? 0 : q.generation);
  endfunction
endclass

class rdma_rule_frame extends rdma_proto_rule;
  `uvm_object_utils(rdma_rule_frame)

  // 功能：构造。
  // 输入/输出及副作用：name 为规则名。
  // 失败/边界：无。
  function new(string name = "rdma_rule_frame");
    super.new(name);
  endfunction

  // 功能：检查 netpkt 链路传输的帧（Ethernet/IPv4/UDP/BTH/ICRC，BTH 在偏移 42）：IP 数据报止于
  //   14 + IP 总长（其后只允许把帧补足 64 字节的填充），ICRC 为数据报末 4 字节（低字节在前）。
  // 输入/输出及副作用：无。
  // 失败/边界：无帧的观测跳过。
  virtual function void on_rx(rdma_link_obs o);
    byte unsigned f[$];
    int unsigned ip_len;
    int unsigned last;
    bit [31:0] icrc;
    int unsigned pad;

    f = o.frame;
    if (f.size() < 62)
      return;
    checked++;
    ip_len = {f[16], f[17]};
    last = 14 + ip_len;
    if ({f[12], f[13]} != 16'h0800 || f[14] != 8'h45 || f[23] != 8'd17)
      fail(o, "not an IPv4/UDP frame");
    if (last > f.size() || (last < f.size() && f.size() > 64) ||
        {f[38], f[39]} != ip_len - 20) begin
      fail(o, $sformatf("IP length %0d / UDP length %0d for a %0dB frame", ip_len,
                        {f[38], f[39]}, f.size()));
      return;
    end
    if ({f[36], f[37]} != 16'd4791)
      fail(o, "UDP destination port is not 4791");
    if (f[43][3:0] != 0 || {f[44], f[45]} != 16'hffff)
      fail(o, $sformatf("BTH TVer %0d P_Key %04h", f[43][3:0], {f[44], f[45]}));
    pad = f[43][5:4];
    if (pad != (4 - o.pkt.payload.size() % 4) % 4)
      fail(o, $sformatf("pad %0d for %0dB payload", pad, o.pkt.payload.size()));
    icrc = {f[last - 1], f[last - 2], f[last - 3], f[last - 4]};
    if (icrc != rocev2_bth::calc_icrc(f, 14, last - 4))
      fail(o, "ICRC mismatch");
  endfunction
endclass

class rdma_rule_psn extends rdma_proto_rule;
  `uvm_object_utils(rdma_rule_psn)

  // 请求方流（Function/源 QPN）的下一个新 PSN；响应方流（Function/QPN）的在途 READ {起始, 包数}。
  protected bit [23:0] next[string];
  protected bit [23:0] read_start[string][$];
  protected int unsigned read_span[string][$];

  // 功能：构造。
  // 输入/输出及副作用：name 为规则名。
  // 失败/边界：无。
  function new(string name = "rdma_rule_psn");
    super.new(name);
  endfunction

  // 功能：仿真请求方：PSN 不得越过下一个新 PSN（等于为新包，早于为重传）；登记 READ。仿真响应方：
  //   READ 响应 PSN 须落在某个在途 READ 的范围内。
  // 输入/输出及副作用：更新流状态。
  // 失败/边界：无。
  virtual function void on_tx(rdma_link_obs o);
    rdma_res_qp q;
    bit [23:0] end_psn;
    string k;

    if (o.pkt.opcode == RDMA_NET_RDMA_READ_RESP)
      check_read_resp(o);
    if (!rdma_proto_checker::request(o.pkt))
      return;
    q = chk.sender(o);
    k = chk.key(o.src, o.pkt.source_qpn);
    end_psn = o.pkt.psn + rdma_proto_checker::span(o.pkt, q == null ? 0 : q.mtu);
    checked++;
    if (next.exists(k) && rdma_proto_checker::after(o.pkt.psn, next[k]))
      fail(o, $sformatf("PSN skips ahead of %06h", next[k]));
    if (!next.exists(k) || rdma_proto_checker::after(end_psn, next[k]))
      next[k] = end_psn;
    track_read(o, q);
  endfunction

  // 功能：远端请求方发来的 READ 请求也要登记（其响应由仿真方发出）。
  // 输入/输出及副作用：更新流状态。
  // 失败/边界：无。
  virtual function void on_rx(rdma_link_obs o);
    if (chk.env.res.funcs[o.src].remote)
      track_read(o, chk.receiver(o));
  endfunction

  // 功能：登记 READ 请求到响应方流（同起始 PSN 的重读不重复登记）。
  // 输入/输出及副作用：更新 read_start/read_span。
  // 失败/边界：非 READ 请求忽略。
  protected function void track_read(rdma_link_obs o, rdma_res_qp q);
    string k;

    if (o.pkt.opcode != RDMA_NET_RDMA_READ_REQUEST)
      return;
    k = chk.key(o.dst, o.pkt.destination_qpn);
    foreach (read_start[k][i])
      if (read_start[k][i] == o.pkt.psn)
        return;
    read_start[k].push_back(o.pkt.psn);
    read_span[k].push_back(rdma_proto_checker::span(o.pkt, q == null ? 0 : q.mtu));
  endfunction

  // 功能：READ 响应 PSN 落在在途 READ 范围内；范围末包出队（连同更早的请求）。
  // 输入/输出及副作用：更新 read_start/read_span。
  // 失败/边界：不在任何范围内报违例。
  protected function void check_read_resp(rdma_link_obs o);
    string k;
    bit [23:0] off;

    k = chk.key(o.src, o.pkt.source_qpn);
    checked++;
    foreach (read_start[k][i]) begin
      off = o.pkt.psn - read_start[k][i];
      if (off >= read_span[k][i])
        continue;
      if (off == read_span[k][i] - 1)
        repeat (i + 1) begin
          void'(read_start[k].pop_front());
          void'(read_span[k].pop_front());
        end
      return;
    end
    fail(o, "READ response PSN outside every outstanding READ");
  endfunction
endclass

class rdma_rule_ack extends rdma_proto_rule;
  `uvm_object_utils(rdma_rule_ack)

  // 响应方流（Function/QPN）已收请求的最大末 PSN 与上次 MSN。
  protected bit [23:0] last_req[string];
  protected bit [23:0] msn[string];

  // 功能：构造。
  // 输入/输出及副作用：name 为规则名。
  // 失败/边界：无。
  function new(string name = "rdma_rule_ack");
    super.new(name);
  endfunction

  // 功能：仿真请求方：RC/URC SEND/WRITE 末包（ONLY/LAST）须置 AckReq（READ/ATOMIC 必有响应，不要求），
  //   UD 不置；仿真响应方：ACK/NAK 检查。
  // 输入/输出及副作用：更新流状态。
  // 失败/边界：无。
  virtual function void on_tx(rdma_link_obs o);
    bit last;

    if (o.pkt.opcode inside {RDMA_NET_ACK, RDMA_NET_NAK, RDMA_NET_ATOMIC_ACK})
      check_ack(o);
    if (!rdma_proto_checker::request(o.pkt))
      return;
    checked++;
    last = o.pkt.segment inside {RDMA_SEG_ONLY, RDMA_SEG_LAST};
    if (o.pkt.transport != RDMA_TRANSPORT_UD && last && !o.pkt.ack_req &&
        o.pkt.opcode inside {RDMA_NET_SEND, RDMA_NET_SEND_WITH_IMM, RDMA_NET_RDMA_WRITE,
                             RDMA_NET_WRITE_WITH_IMM})
      fail(o, "last packet of a SEND/WRITE without AckReq");
    if (o.pkt.transport == RDMA_TRANSPORT_UD && o.pkt.ack_req)
      fail(o, "UD packet with AckReq");
    note_request(o);
  endfunction

  // 功能：远端请求方的请求只在 rx 可见，同样登记。
  // 输入/输出及副作用：更新 last_req。
  // 失败/边界：无。
  virtual function void on_rx(rdma_link_obs o);
    if (chk.env.res.funcs[o.src].remote && rdma_proto_checker::request(o.pkt))
      note_request(o);
  endfunction

  // 功能：登记请求的末 PSN 到其响应方流。
  // 输入/输出及副作用：更新 last_req。
  // 失败/边界：无。
  protected function void note_request(rdma_link_obs o);
    rdma_res_qp q;
    bit [23:0] end_psn;
    string k;

    k = chk.key(o.dst, o.pkt.destination_qpn);
    q = chk.receiver(o);
    end_psn = o.pkt.psn + rdma_proto_checker::span(o.pkt, q == null ? 0 : q.mtu) - 1;
    if (!last_req.exists(k) || rdma_proto_checker::after(end_psn, last_req[k]))
      last_req[k] = end_psn;
  endfunction

  // 功能：ACK/NAK：PSN 不超过已收请求的最大 PSN；MSN 不回退；ACK syndrome 高 3 位为 0，NAK 为 RNR
  //   （001xxxxx）或 0x60..0x63。
  // 输入/输出及副作用：更新 msn。
  // 失败/边界：无。
  protected function void check_ack(rdma_link_obs o);
    bit [7:0] s;
    string k;

    k = chk.key(o.src, o.pkt.source_qpn);
    s = o.pkt.aeth_syndrome;
    checked++;
    if (!last_req.exists(k) || rdma_proto_checker::after(o.pkt.psn, last_req[k]))
      fail(o, "acknowledges a PSN that was never requested");
    if (msn.exists(k) && rdma_proto_checker::after(msn[k], o.pkt.aeth_msn))
      fail(o, $sformatf("MSN went back from %06h to %06h", msn[k], o.pkt.aeth_msn));
    msn[k] = o.pkt.aeth_msn;
    if (o.pkt.opcode != RDMA_NET_NAK && s[7:5] != 3'b000)
      fail(o, $sformatf("ACK syndrome %02h", s));
    if (o.pkt.opcode == RDMA_NET_NAK && s[7:5] != 3'b001 && !(s inside {[8'h60 : 8'h63]}))
      fail(o, $sformatf("NAK syndrome %02h", s));
  endfunction
endclass

class rdma_rule_rnr extends rdma_proto_rule;
  `uvm_object_utils(rdma_rule_rnr)

  // 请求方流（Function/QPN）在此时刻之前不得重发。
  protected time hold[string];

  // 功能：构造。
  // 输入/输出及副作用：name 为规则名。
  // 失败/边界：无。
  function new(string name = "rdma_rule_rnr");
    super.new(name);
  endfunction

  // 功能：IBTA RNR 定时器编码 → 时间（0 为 655.36ms，1..31 为 0.01ms..491.52ms）。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  static function time timer(bit [4:0] code);
    int unsigned table_us[32] = '{655360, 10, 20, 30, 40, 60, 80, 120, 160, 240, 320, 480, 640,
                                   960, 1280, 1920, 2560, 3840, 5120, 7680, 10240, 15360, 20480,
                                   30720, 40960, 61440, 81920, 122880, 163840, 245760, 327680,
                                   491520};

    return table_us[code] * 1us;
  endfunction

  // 功能：仿真响应方的 RNR NAK 编码须为其 QP 的 min_rnr（URC 为 URC_RNR_CODE），并登记请求方等待；
  //   仿真请求方的请求不得早于等待结束。
  // 输入/输出及副作用：更新 hold。
  // 失败/边界：无。
  virtual function void on_tx(rdma_link_obs o);
    rdma_res_qp r;
    bit [4:0] want;
    string k;

    if (rnr_nak(o)) begin
      r = chk.sender(o);
      checked++;
      want = r != null && r.urc ? rdma_drv_qp::URC_RNR_CODE : chk.env.cfg.min_rnr;
      if (o.pkt.aeth_syndrome[4:0] != want)
        fail(o, $sformatf("RNR timer code %0d, QP min_rnr %0d", o.pkt.aeth_syndrome[4:0], want));
      note(o);
      return;
    end
    k = chk.key(o.src, o.pkt.source_qpn);
    if (!rdma_proto_checker::request(o.pkt) || !hold.exists(k))
      return;
    checked++;
    if ($time < hold[k])
      fail(o, $sformatf("retried %0t before the RNR timer expired", hold[k] - $time));
    hold.delete(k);
  endfunction

  // 功能：远端响应方发来的 RNR NAK 也登记请求方等待。
  // 输入/输出及副作用：更新 hold。
  // 失败/边界：无。
  virtual function void on_rx(rdma_link_obs o);
    if (chk.env.res.funcs[o.src].remote && rnr_nak(o))
      note(o);
  endfunction

  // 功能：是否为 RNR NAK。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  protected function bit rnr_nak(rdma_link_obs o);
    return o.pkt.opcode == RDMA_NET_NAK && o.pkt.aeth_syndrome[7:5] == 3'b001;
  endfunction

  // 功能：登记请求方（目的 Function/QPN）的最早重发时刻。
  // 输入/输出及副作用：更新 hold。
  // 失败/边界：无。
  protected function void note(rdma_link_obs o);
    hold[chk.key(o.dst, o.pkt.destination_qpn)] =
      $time + timer(o.pkt.aeth_syndrome[4:0]);
  endfunction
endclass

class rdma_rule_state extends rdma_proto_rule;
  `uvm_object_utils(rdma_rule_state)

  // 功能：构造。
  // 输入/输出及副作用：name 为规则名。
  // 失败/边界：无。
  function new(string name = "rdma_rule_state");
    super.new(name);
  endfunction

  // 功能：发送 QP 存在；请求只在 RTS/SQD/ERR（错误前已在途）发出，响应在 RTR 及之后发出；
  //   仿真目的 Function 上的目的 QP 存在。
  // 输入/输出及副作用：无。
  // 失败/边界：无。
  virtual function void on_tx(rdma_link_obs o);
    rdma_res_qp s;
    rdma_drv_qp_state_e st;

    s = chk.sender(o);
    checked++;
    if (s == null) begin
      fail(o, $sformatf("sent by unknown QP %0d", o.pkt.source_qpn));
      return;
    end
    st = s.qp.cur_state;
    if (rdma_proto_checker::request(o.pkt) &&
        !(st inside {RDMA_DRV_QPS_RTS, RDMA_DRV_QPS_SQD, RDMA_DRV_QPS_ERR}))
      fail(o, {"request sent in state ", st.name()});
    if (!rdma_proto_checker::request(o.pkt) && st inside {RDMA_DRV_QPS_RESET, RDMA_DRV_QPS_INIT})
      fail(o, {"response sent in state ", st.name()});
    if (!chk.env.res.funcs[o.dst].remote && chk.receiver(o) == null)
      fail(o, $sformatf("destination QP %0d does not exist", o.pkt.destination_qpn));
  endfunction
endclass

class rdma_rule_ud extends rdma_proto_rule;
  `uvm_object_utils(rdma_rule_ud)

  // 功能：构造。
  // 输入/输出及副作用：name 为规则名。
  // 失败/边界：无。
  function new(string name = "rdma_rule_ud");
    super.new(name);
  endfunction

  // 功能：UD 报文单包、载荷 ≤ 发送方 MTU。
  // 输入/输出及副作用：无。
  // 失败/边界：无。
  virtual function void on_tx(rdma_link_obs o);
    rdma_res_qp s;

    if (o.pkt.transport != RDMA_TRANSPORT_UD)
      return;
    s = chk.sender(o);
    checked++;
    if (o.pkt.segment != RDMA_SEG_ONLY)
      fail(o, {"UD segment ", o.pkt.segment.name()});
    if (s != null && o.pkt.payload.size() > s.mtu)
      fail(o, $sformatf("UD payload %0dB exceeds MTU %0d", o.pkt.payload.size(), s.mtu));
  endfunction
endclass
