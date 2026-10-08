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

  // 功能：构造尚未绑定 checker 的协议规则基对象，并把 UVM 名作为偏差清单中的稳定规则标识。
  // 输入/输出及副作用：name 写入对象名；chk 保持 null，checked 从零开始，不创建或拥有 checker。
  // 失败/边界：具体规则必须在 build_phase 被绑定到 chk 后才能调用 fail；规则名应与 cfg.deviations 完全一致。
  function new(string name = "rdma_proto_rule");
    super.new(name);
  endfunction

  // 功能：提供仿真 NIC 发送观测的可覆盖检查钩子，基类实现有意不施加规则。
  // 输入/输出及副作用：o 为发送观测；基类不读取它，也不修改 checked 或规则状态。
  // 失败/边界：直接使用基类等价于关闭 TX 检查；派生类负责判空、计数及调用 fail。
  virtual function void on_tx(rdma_link_obs o);
  endfunction

  // 功能：提供链路交付观测的可覆盖检查钩子，基类实现有意不施加规则。
  // 输入/输出及副作用：o 为接收观测；基类不读取它，也不修改 checked 或规则状态。
  // 失败/边界：直接使用基类等价于关闭 RX 检查；派生类负责判空、计数及调用 fail。
  virtual function void on_rx(rdma_link_obs o);
  endfunction

  // 功能：把观测的路由、opcode、PSN 与规则原因格式化后交给 checker 统一报告。
  // 输入/输出及副作用：读取 o/pkt 与当前规则名，调用 chk.violation 并增加对应违例计数。
  // 失败/边界：要求 chk、o 和 o.pkt 均已有效绑定；偏差降级策略由 checker 决定，本函数不吞掉违例。
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

  // 功能：构造协议 checker 组件，并建立分别接收发送、交付观测的两个 analysis export。
  // 输入/输出及副作用：name/parent 建立 UVM 层级；rules/violations 为空，env 仍是非拥有空引用。
  // 失败/边界：构造后必须由 env 绑定环境引用并执行 build_phase，未建规则时观测将不会被检查。
  function new(string name = "rdma_proto_checker", uvm_component parent = null);
    super.new(name, parent);
    tx_export = new("tx_export", this);
    rx_export = new("rx_export", this);
  endfunction

  // 功能：按稳定类型名经 UVM factory 创建全部协议规则，并把每条规则回绑到当前 checker。
  // 输入/输出及副作用：phase 传给父类；按声明顺序填充 rules，允许 factory override 单条规则实现。
  // 失败/边界：factory 必须为每个名字返回兼容 rdma_proto_rule 的非空对象；void cast 不提供恢复，
  //   类型注册缺失属于测试环境配置错误。
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
  // 输入/输出及副作用：读取 env 中源 Function 的 remote 标志；本地源观测按顺序调用全部规则并更新其状态。
  // 失败/边界：远端源发送观测有意跳过以免把外部实现当 DUT；要求 o、pkt、env 及源索引均有效。
  function void write_tx(rdma_link_obs o);
    if (env.res.funcs[o.src].remote)
      return;
    foreach (rules[i])
      rules[i].on_tx(o);
  endfunction

  // 功能：把每条已交付的链路观测广播给全部协议规则，覆盖本地与远端来源。
  // 输入/输出及副作用：逐条调用 on_rx，使各规则可更新 PSN、ACK 或 RNR 跟踪状态。
  // 失败/边界：要求 o/pkt 有效且 build_phase 已完成；空 rules 队列时有意不产生诊断。
  function void write_rx(rdma_link_obs o);
    foreach (rules[i])
      rules[i].on_rx(o);
  endfunction

  // 功能：记录一条规则违例；配置为已知偏差的规则降级成 info，其余作为 UVM_ERROR。
  // 输入/输出及副作用：rule 对应计数自增，并用 msg 形成 UVM 报告；不改变规则检查次数。
  // 失败/边界：未知规则名仍可计数并按非偏差报错；相同违例不去重，env/cfg 必须已绑定。
  function void violation(string rule, string msg);
    violations[rule]++;
    if (env.cfg.deviates(rule))
      `uvm_info("RDMA_PROTO", {"deviation ", rule, ": ", msg}, UVM_MEDIUM)
    else
      `uvm_error("RDMA_PROTO", {rule, ": ", msg})
  endfunction

  // 功能：在报告阶段按规则顺序汇总 checked/violations 计数并输出一条稳定摘要。
  // 输入/输出及副作用：phase 未被修改；只读取 rules 与 violations，通过 UVM_INFO 发布统计。
  // 失败/边界：从未违例的规则按零计；空规则集合仍输出空摘要，不改变最终 UVM 错误计数。
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

  // 功能：判断报文 opcode 是否属于会消费请求 PSN 的 SEND/WRITE/READ/ATOMIC 请求集合。
  // 输入/输出及副作用：只读取 p.opcode 并返回布尔值，不修改报文或 checker 状态。
  // 失败/边界：ACK/NAK、READ 响应和未知 opcode 返回 0；调用者必须传入非空 packet。
  static function bit request(rdma_packet p);
    return p.opcode inside {RDMA_NET_SEND, RDMA_NET_SEND_WITH_IMM, RDMA_NET_RDMA_WRITE,
                            RDMA_NET_WRITE_WITH_IMM, RDMA_NET_RDMA_READ_REQUEST,
                            RDMA_NET_ATOMIC_CMP_SWAP, RDMA_NET_ATOMIC_FETCH_ADD};
  endfunction

  // 功能：按 24 位环形序号的半空间规则判断 a 是否严格晚于 b。
  // 输入/输出及副作用：返回 (a-b) 位于 1..0x7fffff 的判断，不修改任何状态。
  // 失败/边界：相等或恰差半圈 0x800000 均返回 0，调用者不得比较相距半圈以上且无上下文的 PSN。
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

  // 功能：构造无持久状态的 RoCEv2 frame 规则对象。
  // 输入/输出及副作用：name 作为规则/偏差标识交给基类；不取得 frame 或 codec 所有权。
  // 失败/边界：由 checker 绑定 chk 后才可报告；没有原始 frame 的观测由 on_rx 有意跳过。
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

  // 功能：构造 PSN 规则，并以空映射开始跟踪各 QP generation 的下一个 PSN 与在途 READ。
  // 输入/输出及副作用：name 作为规则标识交给基类；next/read_start/read_span 均不预建流状态。
  // 失败/边界：首次观测负责建立流；同一测试复用规则对象不会自动清除历史，生命周期应限于一个 env。
  function new(string name = "rdma_rule_psn");
    super.new(name);
  endfunction

  // 功能：仿真请求方：PSN 不得越过下一个新 PSN（等于为新包，早于为重传）；登记 READ。仿真响应方：
  //   READ 响应 PSN 须落在某个在途 READ 的范围内。
  // 输入/输出及副作用：读取发送方 QP/MTU，更新 next 与 READ 队列，遇到 READ 响应还会消费匹配范围。
  // 失败/边界：非请求且非 READ 响应被忽略；发送 QP 缺失时按单 PSN 检查并由 state 规则另行报错，
  //   PSN 回退视作允许的重传。
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

  // 功能：在交付路径登记远端请求方的 READ，使随后由仿真响应方发出的 READ 响应具有合法范围。
  // 输入/输出及副作用：远端源观测调用 track_read，并读取目的 QP 的 MTU；其他观测不修改状态。
  // 失败/边界：本地来源已在 on_tx 登记，故此处有意跳过以免重复；缺失 QP 时 span 按一个包退化。
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

  // 功能：构造 ACK 规则，并从空状态开始记录各响应方流的最大请求 PSN 与最高 MSN。
  // 输入/输出及副作用：name 作为规则/偏差标识交给基类；last_req/msn 不预建条目。
  // 失败/边界：状态依赖请求先于响应被观测；对象跨测试复用会保留历史，因此应随 env 重建。
  function new(string name = "rdma_rule_ack");
    super.new(name);
  endfunction

  // 功能：仿真请求方：RC/URC SEND/WRITE 末包（ONLY/LAST）须置 AckReq（READ/ATOMIC 必有响应，不要求），
  //   UD 不置；仿真响应方：ACK/NAK 检查。
  // 输入/输出及副作用：检查 AckReq/UD 约束，登记请求末 PSN；ACK/NAK/ATOMIC_ACK 还更新 MSN 状态。
  // 失败/边界：非请求响应只走 ACK 检查；发送/接收 QP 缺失时 note_request 按单 PSN 退化并由 state
  //   规则负责对象存在性诊断。
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

  // 功能：对只在接收观测可见的远端请求登记其响应方流最大末 PSN。
  // 输入/输出及副作用：仅 remote 且属于请求集合时调用 note_request 更新 last_req。
  // 失败/边界：本地请求已由 on_tx 登记而有意跳过；非请求和远端标志为零时保持状态不变。
  virtual function void on_rx(rdma_link_obs o);
    if (chk.env.res.funcs[o.src].remote && rdma_proto_checker::request(o.pkt))
      note_request(o);
  endfunction

  // 功能：按请求 span 计算最后占用 PSN，并单调提升目的 Function/QP generation 对应的 last_req。
  // 输入/输出及副作用：读取 receiver MTU 与 packet PSN/RETH 长度，更新 last_req；旧包重传不回退记录。
  // 失败/边界：目的 QP 不存在时按 span=1 记录；调用者必须只传请求，24 位加法按协议自然回绕。
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
  // 输入/输出及副作用：读取响应 PSN/AETH，校验 last_req，单调性检查后写入当前 msn，并通过 fail 报告
  //   非法 syndrome。
  // 失败/边界：未见对应请求也会保存 MSN 以便检查后续响应；NAK 只接受 RNR 类或 0x60..0x63，未知
  //   ACK syndrome 不被静默放行。
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

  // 功能：构造 RNR 定时规则，并以空 hold 表开始跟踪每个请求方流的最早重试时刻。
  // 输入/输出及副作用：name 作为规则/偏差标识交给基类；不启动 timer 线程，截止时间按观测时刻计算。
  // 失败/边界：规则对象跨测试复用会保留尚未消费的 hold，应与单个 env 生命周期一致。
  function new(string name = "rdma_rule_rnr");
    super.new(name);
  endfunction

  // 功能：把 5 位 IBTA RNR 定时器编码查表转换为仿真时间（0 为 655.36ms，1..31 为
  //   0.01ms..491.52ms）。
  // 输入/输出及副作用：code 直接索引固定 32 项微秒表并返回 time，不修改规则状态。
  // 失败/边界：code 类型限定索引为 0..31；结果受当前 timescale 精度量化，不模拟真实主机调度延迟。
  static function time timer(bit [4:0] code);
    int unsigned table_us[32] = '{655360, 10, 20, 30, 40, 60, 80, 120, 160, 240, 320, 480, 640,
                                   960, 1280, 1920, 2560, 3840, 5120, 7680, 10240, 15360, 20480,
                                   30720, 40960, 61440, 81920, 122880, 163840, 245760, 327680,
                                   491520};

    return table_us[code] * 1us;
  endfunction

  // 功能：仿真响应方的 RNR NAK 编码须为其 QP 的 min_rnr（URC 为 URC_RNR_CODE），并登记请求方等待；
  //   仿真请求方的请求不得早于等待结束。
  // 输入/输出及副作用：RNR NAK 时校验 syndrome 低位并写 hold；请求重试时比较 $time、报告过早重试，
  //   随后删除该流截止时间。
  // 失败/边界：没有 hold 的请求不检查；即使重试过早也消费 hold，避免同一违规级联，发送 QP 缺失时
  //   使用 env 配置的普通 RC min_rnr。
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

  // 功能：对远端响应方经接收路径送来的 RNR NAK 登记本地请求方的重试截止时间。
  // 输入/输出及副作用：仅 remote 且 rnr_nak 为真时调用 note 更新 hold，其他观测不变。
  // 失败/边界：本地响应方的 NAK 已由 on_tx 处理而有意跳过；此处不校验远端 timer 是否匹配本地配置。
  virtual function void on_rx(rdma_link_obs o);
    if (chk.env.res.funcs[o.src].remote && rnr_nak(o))
      note(o);
  endfunction

  // 功能：判断观测是否为 opcode=NAK 且 AETH syndrome 高三位为 001 的 RNR NAK。
  // 输入/输出及副作用：只读 o.pkt 并返回布尔值，不修改 hold 或计数。
  // 失败/边界：不区分低五位的 32 种 timer 编码；调用者必须提供非空观测与 packet。
  protected function bit rnr_nak(rdma_link_obs o);
    return o.pkt.opcode == RDMA_NET_NAK && o.pkt.aeth_syndrome[7:5] == 3'b001;
  endfunction

  // 功能：以 RNR NAK 的目的 Function/QPN generation 为请求方流，登记 $time 加 timer 的重试截止。
  // 输入/输出及副作用：读取 syndrome 低五位并覆盖该流 hold；不创建独立定时线程。
  // 失败/边界：同一流再次收到 RNR NAK 会以后一次观测重新计时；QPN 不存在时 key 使用 generation 0。
  protected function void note(rdma_link_obs o);
    hold[chk.key(o.dst, o.pkt.destination_qpn)] =
      $time + timer(o.pkt.aeth_syndrome[4:0]);
  endfunction
endclass

class rdma_rule_state extends rdma_proto_rule;
  `uvm_object_utils(rdma_rule_state)

  // 功能：构造无持久状态的 QP 状态与目的存在性规则。
  // 输入/输出及副作用：name 作为规则/偏差标识交给基类；不持有 QP，只在观测时查询资源库。
  // 失败/边界：checker/env 绑定前不能检查；远端目的 QP 不由本地资源库证明，按设计跳过存在性检查。
  function new(string name = "rdma_rule_state");
    super.new(name);
  endfunction

  // 功能：发送 QP 存在；请求只在 RTS/SQD/ERR（错误前已在途）发出，响应在 RTR 及之后发出；
  //   仿真目的 Function 上的目的 QP 存在。
  // 输入/输出及副作用：读取资源库中发送/接收 QP 与发送 QP 当前状态，只增加 checked 或发布违例，
  //   不修改资源状态。
  // 失败/边界：发送 QP 缺失时只报告该主错误并返回；目的为 remote 时无法查询其外部资源，故不检查
  //   destination QP 存在性。
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

  // 功能：构造无持久状态的 UD 分段与 MTU 规则。
  // 输入/输出及副作用：name 作为规则/偏差标识交给基类；不持有 QP 或 packet。
  // 失败/边界：由 checker 绑定后才能报告；非 UD 观测由 on_tx 有意跳过。
  function new(string name = "rdma_rule_ud");
    super.new(name);
  endfunction

  // 功能：检查 UD 报文必须使用 ONLY 分段，且在发送 QP 可查询时 payload 不超过其 MTU。
  // 输入/输出及副作用：只读观测和资源库，UD 报文增加 checked，违规经 fail 报告而不修改 QP。
  // 失败/边界：非 UD 立即跳过；发送 QP 缺失时不做 MTU 比较，存在性由 rdma_rule_state 单独报告。
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
