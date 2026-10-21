// 目录：验证组件层 tb/rdma_biz_cfg.sv。
// 层：验证组件（配置）。
// 职责：定义运行模式、Function 角色，以及“业务模板” rdma_biz_cfg：每种业务类型（send/write/read/
//   atomic/ud/urc）各自持有 QP 参数、内存参数、报文属性和流量分布。业务模板是资源与流量参数的唯一
//   配置源：ctrl agent 建 QP 时把 QP/报文参数写入 rdma_res_qp，业务序列按流量分布逐条生成消息。
//   分布类参数（长度、SGE）保存为表达式字符串，每条消息经 rdma_value_spec 单独求值。
// 依赖：rdma_biz_types（模式/角色/业务枚举与参数结构）、rdma_env_items 的 rdma_verb_op_e、
//   net_packet 的 payload_mode_e、rdma_types_pkg 的状态码。
// 所有权：模板由 rdma_env_cfg 持有；表达式求值器可由适配层（aip_core）替换。
// 生命周期：测试 build 阶段创建并加载参数，env build 阶段 finalize（解析继承值、校验、冻结），
//   之后只读。

// 设计说明：分布表达式在 env 包内只支持最小语法，避免 env 依赖参数库；适配层可用 aip_core 的完整
//   语法（权重、inc/dec 等）替换本类。表达式在每条消息生成时求值，因此一个参数描述的是分布而非定值。
class rdma_value_spec extends uvm_object;
  `uvm_object_utils(rdma_value_spec)

  // 功能：构造只支持定值、闭区间和候选列表的默认表达式求值器。
  // 输入/输出及副作用：name 为 UVM 名；对象无状态，不持有随机源（使用 $urandom，随种子复现）。
  // 失败/边界：构造不会校验任何表达式；不支持的语法在 eval 时返回失败原因。
  function new(string name = "rdma_value_spec");
    super.new(name);
  endfunction

  // 功能：按顶层逗号拆分表达式（方括号、花括号、圆括号内的逗号不拆），并去掉各段首尾空白。
  // 输入/输出及副作用：s 为输入表达式，parts 输出各段；不修改输入。
  // 失败/边界：括号不配对时按已扫描深度继续拆分，由后续单段解析报告错误；空串返回一个空段。
  static function void split_top(string s, output string parts[$]);
    int depth;
    string cur;

    parts.delete();
    depth = 0;
    cur = "";
    foreach (s[i]) begin
      if (s[i] inside {"[", "{", "("})
        depth++;
      else if (s[i] inside {"]", "}", ")"} && depth > 0)
        depth--;
      if (s[i] == "," && depth == 0) begin
        parts.push_back(strip(cur));
        cur = "";
      end
      else
        cur = {cur, string'(s[i])};
    end
    parts.push_back(strip(cur));
  endfunction

  // 功能：去掉字符串首尾的空格与制表符。
  // 输入/输出及副作用：返回新字符串，不修改输入。
  // 失败/边界：全空白输入返回空串。
  static function string strip(string s);
    int first;
    int last;

    first = 0;
    last = s.len() - 1;
    while (first <= last && s[first] inside {" ", "\t"})
      first++;
    while (last >= first && s[last] inside {" ", "\t"})
      last--;
    if (first > last)
      return "";
    return s.substr(first, last);
  endfunction

  // 功能：解析一个十进制或 0x 前缀十六进制的非负整数字面量（允许下划线分隔）。
  // 输入/输出及副作用：s 为输入，value 输出数值，返回是否成功；不修改输入。
  // 失败/边界：空串、含非数字字符或超过 64 位的字面量返回 0。
  static function bit parse_number(string s, output longint unsigned value);
    string t;
    bit hex;
    int unsigned digits;

    value = 0;
    t = strip(s);
    hex = t.len() > 2 && t[0] == "0" && (t[1] == "x" || t[1] == "X");
    digits = 0;
    for (int i = hex ? 2 : 0; i < t.len(); i++) begin
      if (t[i] == "_")
        continue;
      if (hex && t[i] inside {["0":"9"], ["a":"f"], ["A":"F"]}) begin
        value = value * 16 + (t[i] inside {["0":"9"]} ? t[i] - "0" :
                              t[i] inside {["a":"f"]} ? t[i] - "a" + 10 : t[i] - "A" + 10);
        digits++;
      end
      else if (!hex && t[i] inside {["0":"9"]}) begin
        value = value * 10 + (t[i] - "0");
        digits++;
      end
      else
        return 1'b0;
    end
    return digits != 0 && digits <= (hex ? 16 : 20);
  endfunction

  // 功能：对一个表达式求值：定值 `v`、闭区间 `[lo:hi]`、候选 `[a,b,c]` 或 `a,b,c`（随机选一项）。
  // 输入/输出及副作用：spec 为表达式，value 输出抽到的值，why 输出失败原因；消耗 $urandom。
  // 失败/边界：语法不支持、区间 lo>hi 或候选为空时返回 0 并给出 why；默认实现不支持权重语法。
  virtual function bit eval(string spec, output longint unsigned value, output string why);
    string parts[$];
    string body;
    string t;
    int colon;
    longint unsigned lo;
    longint unsigned hi;

    value = 0;
    why = "";
    t = strip(spec);
    split_top(t, parts);
    if (parts.size() > 1)
      return eval(parts[$urandom_range(parts.size() - 1, 0)], value, why);
    if (t.len() >= 2 && t[0] == "[" && t[t.len() - 1] == "]") begin
      body = t.substr(1, t.len() - 2);
      split_top(body, parts);
      if (parts.size() > 1)
        return eval(parts[$urandom_range(parts.size() - 1, 0)], value, why);
      colon = -1;
      foreach (body[i])
        if (body[i] == ":" && colon < 0)
          colon = i;
      if (colon <= 0 || !parse_number(body.substr(0, colon - 1), lo) ||
          !parse_number(body.substr(colon + 1, body.len() - 1), hi) || lo > hi) begin
        why = {"invalid range: ", spec};
        return 1'b0;
      end
      value = {$urandom, $urandom};
      if (hi - lo != 64'hffff_ffff_ffff_ffff)
        value = lo + value % (hi - lo + 1);
      return 1'b1;
    end
    if (!parse_number(t, value)) begin
      why = {"unsupported value expression: ", spec};
      return 1'b0;
    end
    return 1'b1;
  endfunction
endclass

// 设计说明：一个业务模板描述“一类流量”而不是逐条消息；QP/内存/报文参数在建资源时一次性使用，
//   流量分布在每条消息生成时使用。finalize 之后模板只读，避免运行中参数漂移。
class rdma_biz_cfg extends uvm_object;
  `uvm_object_utils(rdma_biz_cfg)

  rdma_biz_kind_e kind;
  bit enable;
  rdma_biz_qp_t qp;
  rdma_biz_mem_t mem;
  rdma_biz_pkt_t pkt;
  rdma_biz_trf_t trf;
  protected bit finalized;

  // 功能：构造 SEND 业务的默认模板：QP 链路参数全部继承环境默认，128KiB 缓冲、8 个 4KiB 槽、MR 全权限，
  //   报文属性沿用链路默认，流量 32 条、长度 [1:4096]、SGE [1:4]、四种数据模式、全部 signaled、双向。
  // 输入/输出及副作用：name 为 UVM 名；不创建资源。
  // 失败/边界：其他业务类型须调用 set_kind 重设类型相关默认值（QP 类型、允许的 verb 权重）。
  function new(string name = "rdma_biz_cfg");
    super.new(name);
    enable = 1'b1;
    finalized = 1'b0;
    qp.depth = 0;
    qp.mtu = 0;
    qp.max_sge = 4;
    qp.psn = 0;
    qp.qkey = '0;
    qp.timeout = -1;
    qp.retry = -1;
    qp.rnr_retry = -1;
    qp.min_rnr = -1;
    mem.buf_bytes = 'h20000;
    mem.slot_bytes = 'h1000;
    mem.slots = 8;
    mem.mr_offset = 0;
    mem.mr_remote_read = 1'b1;
    mem.mr_remote_write = 1'b1;
    mem.mr_remote_atomic = 1'b1;
    pkt.vlan_en = 1'b0;
    pkt.vlan_id = 0;
    pkt.src_ip = '0;
    pkt.dst_ip = '0;
    pkt.udp_sport = 0;
    trf.count = 32;
    trf.len = "[1:4096]";
    trf.sge = "[1:4]";
    trf.data_mode = "RANDOM,FIXED,INCREMENT,PATTERN";
    trf.signaled_pct = 100;
    trf.dir = 2;
    set_kind(RDMA_BIZ_SEND);
  endfunction

  // 功能：设置业务类型，并把各 verb 权重重置为“允许的 verb 为 1、其余为 0”。
  // 输入/输出及副作用：k 为业务类型；覆盖 kind 与 trf.w_* 字段，不改其他参数。
  // 失败/边界：finalize 后调用会被忽略并报错，模板已冻结。
  function void set_kind(rdma_biz_kind_e k);
    if (finalized) begin
      `uvm_error("RDMA_BIZ", {"set_kind after finalize: ", k.name()})
      return;
    end
    kind = k;
    trf.w_send = allows(RDMA_VERB_SEND);
    trf.w_send_imm = allows(RDMA_VERB_SEND_IMM);
    trf.w_write = allows(RDMA_VERB_WRITE);
    trf.w_write_imm = allows(RDMA_VERB_WRITE_IMM);
    trf.w_read = allows(RDMA_VERB_READ);
    trf.w_cas = allows(RDMA_VERB_CMP_SWAP);
    trf.w_faa = allows(RDMA_VERB_FETCH_ADD);
  endfunction

  // 功能：返回业务的参数名（send/write/read/atomic/ud/urc），即命令行路径 rdma.biz.<名称>。
  // 输入/输出及副作用：纯查询，按 kind 映射。
  // 失败/边界：kind 为未列出的值时返回 "unknown"。
  function string biz_name();
    case (kind)
      RDMA_BIZ_SEND:   return "send";
      RDMA_BIZ_WRITE:  return "write";
      RDMA_BIZ_READ:   return "read";
      RDMA_BIZ_ATOMIC: return "atomic";
      RDMA_BIZ_UD:     return "ud";
      RDMA_BIZ_URC:    return "urc";
      default:         return "unknown";
    endcase
  endfunction

  // 功能：判断该业务类型是否允许某个 verb（RECV 由序列按需配套投递，不属于业务 verb）。
  // 输入/输出及副作用：op 为输入，返回 1/0，不修改模板。
  // 失败/边界：未知业务类型对所有 verb 返回 0。
  function bit allows(rdma_verb_op_e op);
    case (kind)
      RDMA_BIZ_SEND:   return op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM};
      RDMA_BIZ_WRITE:  return op inside {RDMA_VERB_WRITE, RDMA_VERB_WRITE_IMM};
      RDMA_BIZ_READ:   return op == RDMA_VERB_READ;
      RDMA_BIZ_ATOMIC: return op inside {RDMA_VERB_CMP_SWAP, RDMA_VERB_FETCH_ADD};
      RDMA_BIZ_UD:     return op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM};
      RDMA_BIZ_URC:    return op inside {RDMA_VERB_SEND, RDMA_VERB_WRITE, RDMA_VERB_WRITE_IMM};
      default:         return 1'b0;
    endcase
  endfunction

  // 功能：返回业务使用的驱动 QP 类型（UD 业务为 UD，其余为 RC；URC 另由 urc() 标记）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无额外分支，未知类型按 RC 处理。
  function rdma_drv_qp_type_e qp_type();
    return kind == RDMA_BIZ_UD ? RDMA_DRV_QPT_UD : RDMA_DRV_QPT_RC;
  endfunction

  // 功能：判断业务是否需要以 URC 模式创建 RC QP。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：只有 RDMA_BIZ_URC 返回 1；对端为远端 Function 时由序列跳过该业务。
  function bit urc();
    return kind == RDMA_BIZ_URC;
  endfunction

  // 功能：返回某个 verb 在本业务中的权重（不允许的 verb 视为 0）。
  // 输入/输出及副作用：op 为输入，读取 trf.w_*。
  // 失败/边界：RECV 与未知 verb 返回 0。
  function int unsigned weight(rdma_verb_op_e op);
    if (!allows(op))
      return 0;
    case (op)
      RDMA_VERB_SEND:      return trf.w_send;
      RDMA_VERB_SEND_IMM:  return trf.w_send_imm;
      RDMA_VERB_WRITE:     return trf.w_write;
      RDMA_VERB_WRITE_IMM: return trf.w_write_imm;
      RDMA_VERB_READ:      return trf.w_read;
      RDMA_VERB_CMP_SWAP:  return trf.w_cas;
      RDMA_VERB_FETCH_ADD: return trf.w_faa;
      default:             return 0;
    endcase
  endfunction

  // 功能：按权重随机选择本业务的一个 verb。
  // 输入/输出及副作用：消耗 $urandom，返回选中的 verb。
  // 失败/边界：finalize 已保证权重和非零；若仍为零则返回 SEND 并报错。
  function rdma_verb_op_e pick_op();
    rdma_verb_op_e ops[7];
    int unsigned total;
    int unsigned r;

    ops = '{RDMA_VERB_SEND, RDMA_VERB_SEND_IMM, RDMA_VERB_WRITE, RDMA_VERB_WRITE_IMM,
            RDMA_VERB_READ, RDMA_VERB_CMP_SWAP, RDMA_VERB_FETCH_ADD};
    total = 0;
    foreach (ops[i])
      total += weight(ops[i]);
    if (total == 0) begin
      `uvm_error("RDMA_BIZ", {biz_name(), ": all verb weights are zero"})
      return RDMA_VERB_SEND;
    end
    r = $urandom_range(total - 1, 0);
    foreach (ops[i]) begin
      if (r < weight(ops[i]))
        return ops[i];
      r -= weight(ops[i]);
    end
    return RDMA_VERB_SEND;
  endfunction

  // 功能：对分布表达式求值并夹到 [lo, hi]。
  // 输入/输出及副作用：spec 为表达式、ev 为求值器；返回夹取后的值，消耗随机数。
  // 失败/边界：求值失败时 uvm_fatal（参数错误不应静默降级）；lo>hi 时返回 lo。
  function int unsigned draw(string what, string spec, int unsigned lo, int unsigned hi,
                             rdma_value_spec ev);
    longint unsigned v;
    string why;

    if (!ev.eval(spec, v, why))
      `uvm_fatal("RDMA_BIZ", $sformatf("%s.trf.%s: %s", biz_name(), what, why))
    if (hi < lo)
      return lo;
    if (v < lo)
      return lo;
    if (v > hi)
      return hi;
    return int'(v);
  endfunction

  // 功能：从 trf.data_mode 候选列表（RANDOM/FIXED/INCREMENT/PATTERN，逗号分隔）随机选一个数据模式。
  // 输入/输出及副作用：消耗随机数，返回 payload_mode_e。
  // 失败/边界：候选名未知时 uvm_fatal；空列表在 finalize 时已拒绝。
  function payload_mode_e pick_data_mode();
    string parts[$];
    string pick;

    rdma_value_spec::split_top(trf.data_mode, parts);
    pick = parts[$urandom_range(parts.size() - 1, 0)].toupper();
    case (pick)
      "RANDOM":    return PAYLOAD_RANDOM;
      "FIXED":     return PAYLOAD_FIXED;
      "INCREMENT": return PAYLOAD_INCREMENT;
      "PATTERN":   return PAYLOAD_PATTERN;
      default: begin
        `uvm_fatal("RDMA_BIZ", {biz_name(), ".trf.data_mode: unknown mode ", pick})
        return PAYLOAD_RANDOM;
      end
    endcase
  endfunction

  // 功能：解析继承值（0/-1 取环境默认）、校验全部参数并冻结模板。
  // 输入/输出及副作用：输入环境默认值；覆盖继承字段并置 finalized，返回状态。
  // 失败/边界：MTU 非 256~4096 的 2 的幂、深度/SGE/槽为零、UD 槽不大于 GRH、缓冲放不下全部槽、IB 编码越界、
  //   VLAN ID 超 12 位、PSN 超 24 位、权重全零或数据模式为空时返回 INVALID_ARGUMENT；重复调用幂等。
  function rdma_status finalize(int unsigned depth, int unsigned mtu, bit [31:0] qkey,
                                int unsigned timeout, int unsigned retry,
                                int unsigned rnr_retry, int unsigned min_rnr);
    string who;
    rdma_verb_op_e ops[7];
    int unsigned total;

    who = {"rdma.biz.", biz_name()};
    if (finalized)
      return rdma_status::success();
    if (qp.depth == 0)
      qp.depth = depth;
    if (qp.mtu == 0)
      qp.mtu = mtu;
    if (qp.qkey == 0)
      qp.qkey = qkey;
    if (qp.timeout < 0)
      qp.timeout = timeout;
    if (qp.retry < 0)
      qp.retry = retry;
    if (qp.rnr_retry < 0)
      qp.rnr_retry = rnr_retry;
    if (qp.min_rnr < 0)
      qp.min_rnr = min_rnr;
    if (!(qp.mtu inside {256, 512, 1024, 2048, 4096}))
      return fail(who, $sformatf("qp.mtu %0d is not 256/512/1024/2048/4096", qp.mtu));
    if (qp.depth == 0 || qp.max_sge == 0 || qp.max_sge > 4)
      return fail(who, $sformatf("qp.depth %0d / qp.max_sge %0d out of range", qp.depth,
                                 qp.max_sge));
    if (qp.psn > 24'hff_ffff)
      return fail(who, $sformatf("qp.psn %0h exceeds 24 bits", qp.psn));
    if (qp.timeout > 31 || qp.retry > 7 || qp.rnr_retry > 7 || qp.min_rnr > 31)
      return fail(who, "qp.timeout/retry/rnr_retry/min_rnr exceed IB encodings");
    if (mem.slot_bytes == 0 || mem.slots == 0)
      return fail(who, "mem.slot_bytes and mem.slots must be nonzero");
    if (kind == RDMA_BIZ_UD && mem.slot_bytes <= 40)
      return fail(who, "UD mem.slot_bytes must exceed the 40-byte GRH");
    if (longint'(mem.mr_offset) + 2 * longint'(mem.slot_bytes) * mem.slots > mem.buf_bytes)
      return fail(who, $sformatf("mem.buf_bytes %0h < mr_offset + 2*slots*slot_bytes",
                                 mem.buf_bytes));
    if (pkt.vlan_id > 12'hfff || pkt.udp_sport > 16'hffff)
      return fail(who, "pkt.vlan_id exceeds 12 bits or pkt.udp_sport exceeds 16 bits");
    ops = '{RDMA_VERB_SEND, RDMA_VERB_SEND_IMM, RDMA_VERB_WRITE, RDMA_VERB_WRITE_IMM,
            RDMA_VERB_READ, RDMA_VERB_CMP_SWAP, RDMA_VERB_FETCH_ADD};
    total = 0;
    foreach (ops[i])
      total += weight(ops[i]);
    if (total == 0)
      return fail(who, "all verb weights allowed by this business are zero");
    if (trf.signaled_pct > 100 || trf.dir > 2)
      return fail(who, "trf.signaled_pct must be 0..100 and trf.dir 0..2");
    if (rdma_value_spec::strip(trf.data_mode) == "")
      return fail(who, "trf.data_mode is empty");
    finalized = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：生成带参数路径前缀的 INVALID_ARGUMENT 状态。
  // 输入/输出及副作用：who 为路径、msg 为原因，返回新状态对象。
  // 失败/边界：只构造状态，不修改模板。
  protected function rdma_status fail(string who, string msg);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, {who, ": ", msg});
  endfunction

  // 功能：返回模板是否已 finalize。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：未 finalize 的模板不得用于建资源。
  function bit is_final();
    return finalized;
  endfunction

  // 功能：生成该业务的生效参数摘要（多行，供 env 打印）。
  // 输入/输出及副作用：纯格式化，不修改模板。
  // 失败/边界：未 finalize 时继承字段显示为 0/-1。
  function string describe();
    return $sformatf({"  rdma.biz.%s %s\n",
                      "    qp : depth=%0d mtu=%0d max_sge=%0d psn=0x%0h qkey=0x%08h timeout=%0d ",
                      "retry=%0d rnr_retry=%0d min_rnr=%0d\n",
                      "    mem: buf_bytes=0x%0h slot_bytes=0x%0h slots=%0d mr_offset=0x%0h ",
                      "mr_rr/rw/ra=%0b%0b%0b\n",
                      "    pkt: vlan_en=%0b vlan_id=%0d src_ip=%08h dst_ip=%08h udp_sport=%0d\n",
                      "    trf: count=%0d w(send/simm/write/wimm/read/cas/faa)=",
                      "%0d/%0d/%0d/%0d/%0d/%0d/%0d ",
                      "len=%s sge=%s data_mode=%s signaled_pct=%0d dir=%0d"},
                     biz_name(), enable ? "enabled" : "disabled",
                     qp.depth, qp.mtu, qp.max_sge, qp.psn, qp.qkey, qp.timeout, qp.retry,
                     qp.rnr_retry, qp.min_rnr,
                     mem.buf_bytes, mem.slot_bytes, mem.slots, mem.mr_offset,
                     mem.mr_remote_read, mem.mr_remote_write, mem.mr_remote_atomic,
                     pkt.vlan_en, pkt.vlan_id, pkt.src_ip, pkt.dst_ip, pkt.udp_sport,
                     trf.count, weight(RDMA_VERB_SEND), weight(RDMA_VERB_SEND_IMM),
                     weight(RDMA_VERB_WRITE), weight(RDMA_VERB_WRITE_IMM), weight(RDMA_VERB_READ),
                     weight(RDMA_VERB_CMP_SWAP), weight(RDMA_VERB_FETCH_ADD),
                     trf.len, trf.sge, trf.data_mode, trf.signaled_pct, trf.dir);
  endfunction
endclass
