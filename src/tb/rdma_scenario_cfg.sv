// 目录：验证组件层 tb/rdma_scenario_cfg.sv。
// 层：验证组件（配置）。
// 职责：定义运行模式、Function 角色，以及“统一场景” rdma_scenario_cfg：单一配置持有 QP 参数、内存参数、报文属性和流量分布。统一场景是资源与流量参数的唯一
//   配置源：ctrl agent 建 QP 时把 QP/报文参数写入 rdma_res_qp，业务序列按流量分布逐条生成消息。
//   分布类参数（长度、SGE）保存为表达式字符串，每条消息经 rdma_value_spec 单独求值。
// 依赖：rdma_scenario_types（模式/角色/传输枚举与参数结构）、rdma_env_items 的 rdma_verb_op_e、
//   net_packet 的 payload_mode_e、rdma_types_pkg 的状态码。
// 所有权：场景由 rdma_env_cfg 持有；表达式求值器可由适配层（aip_core）替换。
// 生命周期：测试 build 阶段创建并加载参数，env build 阶段 finalize 校验并冻结；初始化前可经项目候选事务原地提交。

// 设计说明：分布表达式在 env 包内只支持最小语法，避免 env 依赖参数库；适配层可用 aip_core 的完整
//   语法（权重、inc/dec 等）替换本类。表达式在每条消息生成时求值，因此一个参数描述的是分布而非定值。
class rdma_value_spec extends uvm_object;
  `uvm_object_utils(rdma_value_spec)

  // 功能：构造只支持定值、闭区间和候选列表的默认表达式求值器。
  // 输入/输出及副作用：name 为 UVM 名；对象无状态，不持有随机源（使用 $urandom，随种子复现）。
  // 失败/边界：构造不会校验任何表达式；不支持的语法在 eval 时返回失败原因。
  extern function new(string	name = "rdma_value_spec");

  // 功能：按顶层逗号拆分表达式（方括号、花括号、圆括号内的逗号不拆），并去掉各段首尾空白。
  // 输入/输出及副作用：s 为输入表达式，parts 输出各段；不修改输入。
  // 失败/边界：括号不配对时按已扫描深度继续拆分，由后续单段解析报告错误；空串返回一个空段。
  extern static function void split_top(string	s, output string	parts[$]);

  // 功能：去掉字符串首尾的空格与制表符。
  // 输入/输出及副作用：返回新字符串，不修改输入。
  // 失败/边界：全空白输入返回空串。
  extern static function string strip(string	s);

  // 功能：解析一个十进制或 0x 前缀十六进制的非负整数字面量（允许下划线分隔）。
  // 输入/输出及副作用：s 为输入，value 仅成功时输出数值，overflow 区分完整数字的溢出；不修改输入、不抽样。
  // 失败/边界：空串/非字面量返回 0 且 overflow=0；超 64 位或超原有位数上限返回 0/overflow=1；失败 value=0。
  extern static function bit parse_number(string	s, output longint unsigned	value, output bit	overflow);

  // 功能：对一个表达式求值：定值 `v`、闭区间 `[lo:hi]`、候选 `[a,b,c]` 或 `a,b,c`（随机选一项）。
  // 输入/输出及副作用：spec 为表达式，value 输出抽到的值，why 输出失败原因；消耗 $urandom。
  // 失败/边界：语法不支持、区间 lo>hi 或候选为空时返回 0 并给出 why；默认实现不支持权重语法；完整字面量/区间端点溢出返回固定诊断，禁止适配器回退重新解释。
  extern virtual function bit eval(string	spec, output longint unsigned	value, output string	why);
endclass

  // 功能：构造只支持定值、闭区间和候选列表的默认表达式求值器。
  // 输入/输出及副作用：name 为 UVM 名；对象无状态，不持有随机源（使用 $urandom，随种子复现）。
  // 失败/边界：构造不会校验任何表达式；不支持的语法在 eval 时返回失败原因。
function rdma_value_spec::new(string	name = "rdma_value_spec");
    super.new(name);
endfunction

  // 功能：按顶层逗号拆分表达式（方括号、花括号、圆括号内的逗号不拆），并去掉各段首尾空白。
  // 输入/输出及副作用：s 为输入表达式，parts 输出各段；不修改输入。
  // 失败/边界：括号不配对时按已扫描深度继续拆分，由后续单段解析报告错误；空串返回一个空段。
function void rdma_value_spec::split_top(string	s, output string	parts[$]);
    int	depth;
    string	cur;

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
function string rdma_value_spec::strip(string	s);
    int	first;
    int	last;

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
  // 输入/输出及副作用：s 为输入，value 仅成功时输出数值，overflow 区分完整数字的溢出；不修改输入、不抽样。
  // 失败/边界：空串/非字面量返回 0 且 overflow=0；超 64 位或超原有位数上限返回 0/overflow=1；失败 value=0。
function bit rdma_value_spec::parse_number(string	s, output longint unsigned	value, output bit	overflow);
    string	t;
    bit	hex;
    bit	exceeded;
    int unsigned	digits;
    int unsigned	digit;
    int unsigned	radix;
    longint unsigned	accumulator;

    value = 0;
    overflow = 0;
    accumulator = 0;
    exceeded = 0;
    t = strip(s);
    hex = t.len() > 2 && t[0] == "0" && (t[1] == "x" || t[1] == "X");
    radix = hex ? 16 : 10;
    digits = 0;
    for (int	i = hex ? 2 : 0; i < t.len(); i++) begin
      if (t[i] == "_")
        continue;
      if (t[i] inside {["0":"9"]})
        digit = t[i] - "0";
      else if (hex && t[i] inside {["a":"f"]})
        digit = t[i] - "a" + 10;
      else if (hex && t[i] inside {["A":"F"]})
        digit = t[i] - "A" + 10;
      else
        return 0;
      digits++;
      // 先证明下一次乘加仍可表示，再计算；溢出后只继续识别是否为完整字面量。
      // 因此任意分布语法不会被当作数值溢出，也不会发布已回绕的 value。
      if (!exceeded) begin
        if (accumulator > (64'hffff_ffff_ffff_ffff - digit) / radix)
          exceeded = 1;
        else
          accumulator = accumulator * radix + digit;
      end
    end
    if (digits == 0)
      return 0;
    overflow = exceeded || digits > (hex ? 16 : 20);
    if (overflow)
      return 0;
    value = accumulator;
    return 1;
endfunction

  // 功能：对一个表达式求值：定值 `v`、闭区间 `[lo:hi]`、候选 `[a,b,c]` 或 `a,b,c`（随机选一项）。
  // 输入/输出及副作用：spec 为表达式，value 输出抽到的值，why 输出失败原因；消耗 $urandom。
  // 失败/边界：语法不支持、区间 lo>hi 或候选为空时返回 0 并给出 why；默认实现不支持权重语法；完整字面量/区间端点溢出返回固定诊断，禁止适配器回退重新解释。
function bit rdma_value_spec::eval(string	spec, output longint unsigned	value, output string	why);
    string	parts[$];
    string	body;
    string	t;
    int	colon;
    longint unsigned	lo;
    longint unsigned	hi;
    bit	number_overflow;

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
      if (colon <= 0) begin
        why = {"invalid range: ", spec};
        return 0;
      end
      if (!parse_number(body.substr(0, colon - 1), lo, number_overflow)) begin
        why = number_overflow ? "numeric literal exceeds 64-bit range" : {"invalid range: ", spec};
        return 0;
      end
      if (!parse_number(body.substr(colon + 1, body.len() - 1), hi, number_overflow)) begin
        why = number_overflow ? "numeric literal exceeds 64-bit range" : {"invalid range: ", spec};
        return 0;
      end
      if (lo > hi) begin
        why = {"invalid range: ", spec};
        return 0;
      end
      value = {$urandom, $urandom};
      if (hi - lo != 64'hffff_ffff_ffff_ffff)
        value = lo + value % (hi - lo + 1);
      return 1'b1;
    end
    if (!parse_number(t, value, number_overflow)) begin
      why = number_overflow ? "numeric literal exceeds 64-bit range" : {"unsupported value expression: ", spec};
      return 1'b0;
    end
    return 1'b1;
endfunction

class rdma_scenario_cfg extends uvm_object;
  `uvm_object_utils(rdma_scenario_cfg)

  rdma_scenario_qp_t	qp;
  rdma_scenario_mem_t	mem;
  rdma_scenario_pkt_t	pkt;
  rdma_scenario_traffic_t	traffic;
  protected bit	finalized;

// 功能：构造 RC SEND 场景，SGE 默认固定 1 以保证短消息不需要裁剪。
// 输入/输出及副作用：name 为 UVM 名；拥有四组值，无设备或内存分配。
// 失败/边界：默认长度保留 [1:4096]；QP max_sge=4，显式多 SGE 表达式由 WR 边界检查。
  extern function new(string	name = "rdma_scenario_cfg");

// 功能：按传输类型判断业务 verb，RECV 由序列配套生成。
// 输入/输出及副作用：op 输入；返回允许位，不修改配置。
// 失败/边界：未知 kind 或 RECV 返回 0。
  extern function bit allows(rdma_verb_op_e	op);

// 功能：将驱动 verb 映射为公开 traffic.op 名。
// 输入/输出及副作用：op 输入；返回小写名称。
// 失败/边界：RECV 或未知枚举返回空串。
  extern function string op_name(rdma_verb_op_e	op);

// 功能：单操作返回匹配权重 1，mix 读取已有七个权重。
// 输入/输出及副作用：op 输入；返回原始权重，故不兼容非零项不会被隐藏。
// 失败/边界：未知 op 返回 0；传输兼容性在 validate 拒绝。
  extern function int unsigned weight(rdma_verb_op_e	op);

// 功能：将场景传输类型映射为驱动 QP 类型。
// 输入/输出及副作用：纯查询；UD 返回 UD，RC/URC 返回 RC。
// 失败/边界：未知类型须在 validate 拒绝后才能创建资源。
  extern function rdma_drv_qp_type_e qp_type();

// 功能：判断是否需要驱动 RC 的 URC 标志。
// 输入/输出及副作用：纯查询 qp.kind。
// 失败/边界：仅 URC 返回 1。
  extern function bit urc();

  // 功能：判断报文参数是否全部继承链路默认。
  // 输入/输出及副作用：比较 VLAN、MAC、IP 和 UDP 源端口字段，无副作用。
  // 失败/边界：任一 MAC/IP/UDP/VLAN 字段非零即视为 override，即使 vlan_en=0。
  extern function bit packet_defaults();

// 功能：确定性校验 QP、操作、MR、槽布局及数据模式，不抽取任何 WR 表达式。
// 输入/输出及副作用：读取四组值，返回首个具体路径错误；不冻结或写配置。
// 失败/边界：非法类型/操作/权限/编码/容量/方向/比例拒绝；表达式随机结果仅在 draw 验证。
  extern function rdma_status validate();

// 功能：验证当前场景后冻结资源创建输入。
// 输入/输出及副作用：成功置 finalized；失败返回 status 且不改变冻结位。
// 失败/边界：每次重新校验，不因旧快照 finalized 返回缓存。
  extern function rdma_status finalize();

// 功能：查询场景是否完成成功验证。
// 输入/输出及副作用：返回 finalized，无副作用。
// 失败/边界：未冻结场景不能建资源。
  extern function bit is_final();

// 功能：原地复制已经预检的四组场景值，保留消费者持有的场景句柄。
// 输入/输出及副作用：candidate 只读；更新 qp/mem/pkt/traffic 和 finalized。
// 失败/边界：调用方必须先完成全事务预检；不分配资源或求值表达式。
  extern function void apply(rdma_scenario_cfg	candidate);

// 功能：构造场景语义拒绝状态，交由项目汇总错误。
// 输入/输出及副作用：message 为完整参数路径原因；返回 INVALID_ARGUMENT。
// 失败/边界：不报告 fatal，不改活动配置。
  extern function rdma_status fail(string	message);

// 功能：按当前单操作或 mix 权重选择一条 WR 的 verb。
// 输入/输出及副作用：消耗一次操作选择随机值，返回 verb。
// 失败/边界：validate 应保证权重和合法；零权重直接 fatal。
  extern function rdma_verb_op_e pick_op();

// 功能：对当前 WR 的单个长度或 SGE 表达式求值一次并严格检查边界。
// 输入/输出及副作用：what 为 traffic 子路径，spec 原文，ev 求值器；返回原抽样值，消耗一次 eval。
// 失败/边界：ev 缺失、表达式失败、lo>hi 或抽样越界 fatal；绝不裁剪或重复采样。
  extern function int unsigned draw(string	what, string	spec, int unsigned	lo, int unsigned	hi, rdma_value_spec	ev);

  // 功能：从已验证候选选择当前 WR 的负载模式。
// 输入/输出及副作用：读取 traffic.data_mode 并消耗一个随机选择值。
// 失败/边界：未知模式 fatal；空候选在 validate 拒绝。
  extern function payload_mode_e pick_data_mode();

// 功能：生成统一场景的紧凑生效摘要。
// 输入/输出及副作用：按值格式化传输类型、队列、操作和表达式，不求值。
// 失败/边界：未 finalize 也可诊断当前输入。
  extern function string describe();

endclass

// 功能：构造 RC SEND 场景，SGE 默认固定 1 以保证短消息不需要裁剪。
// 输入/输出及副作用：name 为 UVM 名；拥有四组值，无设备或内存分配。
// 失败/边界：默认长度保留 [1:4096]；QP max_sge=4，显式多 SGE 表达式由 WR 边界检查。
function rdma_scenario_cfg::new(string	name = "rdma_scenario_cfg");
  super.new(name);
  qp = '{RDMA_SCENARIO_RC, 256, 1024, 4, 0, 0, 32'h8001_0000, 14, 7, 7, 1};
  mem = '{'h20000, 'h1000, 8, 0, 1, 1, 1};
  pkt = '{0, 0, 0, 0, 0, 0, 0};
  traffic.op = "send";
  traffic.count = 32;
  traffic.w_send = 1;
  traffic.w_send_imm = 1;
  traffic.w_write = 1;
  traffic.w_write_imm = 1;
  traffic.w_read = 1;
  traffic.w_cas = 1;
  traffic.w_faa = 1;
  traffic.len = "[1:4096]";
  traffic.sge = "1";
  traffic.data_mode = "RANDOM,FIXED,INCREMENT,PATTERN";
  traffic.data_fixed = "0";
  traffic.data_pattern = "{0}";
  traffic.imm = "";
  traffic.signaled_pct = 100;
  traffic.dir = 2;
  finalized = 0;
endfunction

// 功能：按传输类型判断业务 verb，RECV 由序列配套生成。
// 输入/输出及副作用：op 输入；返回允许位，不修改配置。
// 失败/边界：未知 kind 或 RECV 返回 0。
function bit rdma_scenario_cfg::allows(rdma_verb_op_e	op);
  case (qp.kind)
    RDMA_SCENARIO_RC: return op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM,
      RDMA_VERB_WRITE, RDMA_VERB_WRITE_IMM, RDMA_VERB_READ, RDMA_VERB_CMP_SWAP, RDMA_VERB_FETCH_ADD};
    RDMA_SCENARIO_UD: return op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM};
    RDMA_SCENARIO_URC: return op inside {RDMA_VERB_SEND, RDMA_VERB_WRITE, RDMA_VERB_WRITE_IMM};
    default: return 0;
  endcase
endfunction

// 功能：将驱动 verb 映射为公开 traffic.op 名。
// 输入/输出及副作用：op 输入；返回小写名称。
// 失败/边界：RECV 或未知枚举返回空串。
function string rdma_scenario_cfg::op_name(rdma_verb_op_e	op);
  case (op)
    RDMA_VERB_SEND: return "send";
    RDMA_VERB_SEND_IMM: return "send_imm";
    RDMA_VERB_WRITE: return "write";
    RDMA_VERB_WRITE_IMM: return "write_imm";
    RDMA_VERB_READ: return "read";
    RDMA_VERB_CMP_SWAP: return "cas";
    RDMA_VERB_FETCH_ADD: return "faa";
    default: return "";
  endcase
endfunction

// 功能：单操作返回匹配权重 1，mix 读取已有七个权重。
// 输入/输出及副作用：op 输入；返回原始权重，故不兼容非零项不会被隐藏。
// 失败/边界：未知 op 返回 0；传输兼容性在 validate 拒绝。
function int unsigned rdma_scenario_cfg::weight(rdma_verb_op_e	op);
  if (traffic.op.tolower() != "mix")
    return traffic.op.tolower() == op_name(op) && op_name(op) != "";
  case (op)
    RDMA_VERB_SEND: return traffic.w_send;
    RDMA_VERB_SEND_IMM: return traffic.w_send_imm;
    RDMA_VERB_WRITE: return traffic.w_write;
    RDMA_VERB_WRITE_IMM: return traffic.w_write_imm;
    RDMA_VERB_READ: return traffic.w_read;
    RDMA_VERB_CMP_SWAP: return traffic.w_cas;
    RDMA_VERB_FETCH_ADD: return traffic.w_faa;
    default: return 0;
  endcase
endfunction

// 功能：将场景传输类型映射为驱动 QP 类型。
// 输入/输出及副作用：纯查询；UD 返回 UD，RC/URC 返回 RC。
// 失败/边界：未知类型须在 validate 拒绝后才能创建资源。
function rdma_drv_qp_type_e rdma_scenario_cfg::qp_type();
  return qp.kind == RDMA_SCENARIO_UD ? RDMA_DRV_QPT_UD : RDMA_DRV_QPT_RC;
endfunction

// 功能：判断是否需要驱动 RC 的 URC 标志。
// 输入/输出及副作用：纯查询 qp.kind。
// 失败/边界：仅 URC 返回 1。
function bit rdma_scenario_cfg::urc();
  return qp.kind == RDMA_SCENARIO_URC;
endfunction

// 功能：判断报文参数是否全部继承链路默认。
// 输入/输出及副作用：比较 VLAN、MAC、IP 和 UDP 源端口字段，无副作用。
// 失败/边界：任一 MAC/IP/UDP/VLAN 字段非零即视为 override，即使 vlan_en=0。
function bit rdma_scenario_cfg::packet_defaults();
  return !pkt.vlan_en && pkt.vlan_id == 0 && pkt.src_mac == 0 && pkt.dst_mac == 0 &&
    pkt.src_ip == 0 && pkt.dst_ip == 0 && pkt.udp_sport == 0;
endfunction

// 功能：确定性校验 QP、操作、MR、槽布局及数据模式，不抽取任何 WR 表达式。
// 输入/输出及副作用：读取四组值，返回首个具体路径错误；不冻结或写配置。
// 失败/边界：非法类型/操作/权限/编码/容量/方向/比例拒绝；表达式随机结果仅在 draw 验证。
function rdma_status rdma_scenario_cfg::validate();
  rdma_verb_op_e	ops[7];
  longint unsigned	total;
  longint unsigned	literal_len;
  longint unsigned	literal_sge;
  int unsigned	length_limit;
  bit	non_atomic;
  bit	has_literal_len;
  bit	has_literal_sge;
  bit	number_overflow;
  string	parts[$];
  string	pattern_spec;
  string	pattern_body;
  ops = '{RDMA_VERB_SEND, RDMA_VERB_SEND_IMM, RDMA_VERB_WRITE, RDMA_VERB_WRITE_IMM,
    RDMA_VERB_READ, RDMA_VERB_CMP_SWAP, RDMA_VERB_FETCH_ADD};
  if (!(qp.kind inside {RDMA_SCENARIO_RC, RDMA_SCENARIO_UD, RDMA_SCENARIO_URC}))
    return fail("rdma.qp.type must be RC, UD or URC");
  if (qp.depth == 0 || qp.depth > 32768 || qp.max_sge == 0 || qp.max_sge > 4)
    return fail("rdma.qp.depth must be 1..32768 and max_sge 1..4");
  if (!(qp.mtu inside {256, 512, 1024, 2048, 4096}))
    return fail("rdma.qp.mtu must be 256/512/1024/2048/4096");
  if (qp.psn > 24'hffffff || qp.dest_qpn > 24'hffffff || qp.timeout < 0 || qp.timeout > 31 ||
      qp.retry < 0 || qp.retry > 7 || qp.rnr_retry < 0 || qp.rnr_retry > 7 ||
      qp.min_rnr < 0 || qp.min_rnr > 31)
    return fail("rdma.qp PSN/timeout/retry/rnr_retry/min_rnr exceeds hardware encoding");
  if (mem.slot_bytes == 0 || mem.slots == 0 ||
      mem.mr_offset > mem.buf_bytes ||
      (mem.slot_bytes != 0 && mem.slots > (mem.buf_bytes - mem.mr_offset) / mem.slot_bytes / 2))
    return fail("rdma.mem requires nonzero slots/slot_bytes and mr_offset+2*slots*slot_bytes <= buf_bytes");
  if (qp.kind == RDMA_SCENARIO_UD && mem.slot_bytes <= 40)
    return fail("rdma.mem.slot_bytes must exceed UD GRH size 40");
  if (pkt.vlan_id > 4095 || pkt.udp_sport > 65535)
    return fail("rdma.pkt.vlan_id must be 0..4095 and udp_sport 0..65535");
  if (rdma_value_spec::strip(traffic.data_fixed) != "" &&
      rdma_value_spec::parse_number(traffic.data_fixed, literal_len, number_overflow) &&
      literal_len > 8'hff)
    return fail("rdma.traffic.data_fixed literal must be 0..255");
  if (rdma_value_spec::strip(traffic.imm) != "" &&
      rdma_value_spec::parse_number(traffic.imm, literal_len, number_overflow) &&
      literal_len > 32'hffff_ffff)
    return fail("rdma.traffic.imm literal must be 0..0xffffffff");
  pattern_spec = rdma_value_spec::strip(traffic.data_pattern);
  if (pattern_spec != "" && pattern_spec.len() >= 2 && pattern_spec[0] == "{" &&
      pattern_spec[pattern_spec.len() - 1] == "}") begin
    pattern_body = pattern_spec.substr(1, pattern_spec.len() - 2);
    rdma_value_spec::split_top(pattern_body, parts);
    foreach (parts[i])
      if (rdma_value_spec::parse_number(parts[i], literal_len, number_overflow) &&
          literal_len > 8'hff)
        return fail("rdma.traffic.data_pattern elements must be 0..255");
  end
  if (traffic.signaled_pct > 100 || traffic.dir > 2 || traffic.count == 0)
    return fail("rdma.traffic requires count>0, signaled_pct 0..100, dir 0..2");
  if (rdma_value_spec::strip(traffic.len) == "" || rdma_value_spec::strip(traffic.sge) == "")
    return fail("rdma.traffic.len/sge must not be empty");
  total = 0;
  non_atomic = 0;
  foreach (ops[i]) begin
    total += weight(ops[i]);
    if (weight(ops[i]) == 0)
      continue;
    if (!(ops[i] inside {RDMA_VERB_CMP_SWAP, RDMA_VERB_FETCH_ADD}))
      non_atomic = 1;
    if (!allows(ops[i]))
      return fail({"rdma.traffic.op incompatible with rdma.qp.type: ", op_name(ops[i])});
    if (ops[i] == RDMA_VERB_READ && !mem.mr_remote_read)
      return fail("rdma.mem.mr_remote_read is required by read");
    if (ops[i] inside {RDMA_VERB_WRITE, RDMA_VERB_WRITE_IMM} && !mem.mr_remote_write)
      return fail("rdma.mem.mr_remote_write is required by write/write_imm");
    if (ops[i] inside {RDMA_VERB_CMP_SWAP, RDMA_VERB_FETCH_ADD} &&
        (!mem.mr_remote_atomic || mem.slot_bytes < 8 || mem.slot_bytes % 8 != 0 || mem.mr_offset % 8 != 0))
      return fail("rdma.mem atomic requires permission, slot_bytes>=8 and 8-byte slot/offset alignment");
  end
  if (total == 0 || total > 32'hffffffff)
    return fail("rdma.traffic.op unknown or mix weight sum outside 1..0xffffffff");
  // 只复用已有字面量识别，不解析或抽取分布。复杂表达式的实际值在每条 WR 边界检查。
  if (non_atomic) begin
    length_limit = mem.slot_bytes;
    if (qp.kind == RDMA_SCENARIO_UD)
      length_limit = qp.mtu < mem.slot_bytes - 40 ? qp.mtu : mem.slot_bytes - 40;
    has_literal_len = rdma_value_spec::parse_number(traffic.len, literal_len, number_overflow);
    if (number_overflow)
      return fail("rdma.traffic.len literal exceeds 64-bit numeric range");
    if (has_literal_len && (literal_len == 0 || literal_len > length_limit))
      return fail("rdma.traffic.len literal exceeds slot/MTU bounds");
    has_literal_sge = rdma_value_spec::parse_number(traffic.sge, literal_sge, number_overflow);
    if (number_overflow)
      return fail("rdma.traffic.sge literal exceeds 64-bit numeric range");
    if (has_literal_sge &&
        (literal_sge == 0 || literal_sge > qp.max_sge || (has_literal_len && literal_sge > literal_len)))
      return fail("rdma.traffic.sge literal exceeds max_sge/length bounds");
  end
  rdma_value_spec::split_top(traffic.data_mode, parts);
  foreach (parts[i])
    if (!(parts[i].toupper() inside {"RANDOM", "FIXED", "INCREMENT", "PATTERN"}))
      return fail({"rdma.traffic.data_mode unknown: ", parts[i]});
  return rdma_status::success();
endfunction

// 功能：验证当前场景后冻结资源创建输入。
// 输入/输出及副作用：成功置 finalized；失败返回 status 且不改变冻结位。
// 失败/边界：每次重新校验，不因旧快照 finalized 返回缓存。
function rdma_status rdma_scenario_cfg::finalize();
  rdma_status	status;
  status = validate();
  if (status.ok())
    finalized = 1;
  return status;
endfunction

// 功能：查询场景是否完成成功验证。
// 输入/输出及副作用：返回 finalized，无副作用。
// 失败/边界：未冻结场景不能建资源。
function bit rdma_scenario_cfg::is_final();
  return finalized;
endfunction

// 功能：原地复制已经预检的四组场景值，保留消费者持有的场景句柄。
// 输入/输出及副作用：candidate 只读；更新 qp/mem/pkt/traffic 和 finalized。
// 失败/边界：调用方必须先完成全事务预检；不分配资源或求值表达式。
function void rdma_scenario_cfg::apply(rdma_scenario_cfg	candidate);
  qp = candidate.qp;
  mem = candidate.mem;
  pkt = candidate.pkt;
  traffic = candidate.traffic;
  finalized = 1;
endfunction

// 功能：构造场景语义拒绝状态，交由项目汇总错误。
// 输入/输出及副作用：message 为完整参数路径原因；返回 INVALID_ARGUMENT。
// 失败/边界：不报告 fatal，不改活动配置。
function rdma_status rdma_scenario_cfg::fail(string	message);
  return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
endfunction

// 功能：按当前单操作或 mix 权重选择一条 WR 的 verb。
// 输入/输出及副作用：消耗一次操作选择随机值，返回 verb。
// 失败/边界：validate 应保证权重和合法；零权重直接 fatal。
function rdma_verb_op_e rdma_scenario_cfg::pick_op();
  rdma_verb_op_e	ops[7];
  int unsigned	total;
  int unsigned	r;
  ops = '{RDMA_VERB_SEND, RDMA_VERB_SEND_IMM, RDMA_VERB_WRITE, RDMA_VERB_WRITE_IMM,
    RDMA_VERB_READ, RDMA_VERB_CMP_SWAP, RDMA_VERB_FETCH_ADD};
  total = 0;
  foreach (ops[i])
    total += weight(ops[i]);
  if (total == 0)
    `uvm_fatal("RDMA_SCENARIO", "rdma.traffic.op has zero weight")
  r = $urandom_range(total - 1, 0);
  foreach (ops[i]) begin
    if (r < weight(ops[i]))
      return ops[i];
    r -= weight(ops[i]);
  end
  return RDMA_VERB_SEND;
endfunction

// 功能：对当前 WR 的单个长度或 SGE 表达式求值一次并严格检查边界。
// 输入/输出及副作用：what 为 traffic 子路径，spec 原文，ev 求值器；返回原抽样值，消耗一次 eval。
// 失败/边界：ev 缺失、表达式失败、lo>hi 或抽样越界 fatal；绝不裁剪或重复采样。
function int unsigned rdma_scenario_cfg::draw(string	what, string	spec, int unsigned	lo, int unsigned	hi, rdma_value_spec	ev);
  longint unsigned	v;
  string	why;
  if (ev == null || !ev.eval(spec, v, why))
    `uvm_fatal("RDMA_SCENARIO", {"rdma.traffic.", what, ": ", why})
  if (hi < lo || v < lo || v > hi)
    `uvm_fatal("RDMA_SCENARIO", $sformatf("rdma.traffic.%s sampled %0d outside [%0d:%0d] from %s", what, v, lo, hi, spec))
  return int'(v);
endfunction

// 功能：从已验证候选选择当前 WR 的负载模式。
// 输入/输出及副作用：读取 traffic.data_mode 并消耗一个随机选择值。
// 失败/边界：未知模式 fatal；空候选在 validate 拒绝。
function payload_mode_e rdma_scenario_cfg::pick_data_mode();
  string	parts[$];
  string	pick;
  rdma_value_spec::split_top(traffic.data_mode, parts);
  pick = parts[$urandom_range(parts.size() - 1, 0)].toupper();
  case (pick)
    "RANDOM": return PAYLOAD_RANDOM;
    "FIXED": return PAYLOAD_FIXED;
    "INCREMENT": return PAYLOAD_INCREMENT;
    "PATTERN": return PAYLOAD_PATTERN;
    default: begin
      `uvm_fatal("RDMA_SCENARIO", {"rdma.traffic.data_mode unknown: ", pick})
      return PAYLOAD_RANDOM;
    end
  endcase
endfunction

// 功能：生成统一场景的紧凑生效摘要。
// 输入/输出及副作用：按值格式化传输类型、队列、操作和表达式，不求值。
// 失败/边界：未 finalize 也可诊断当前输入。
function string rdma_scenario_cfg::describe();
  // 摘要保留原始表达式，便于诊断参数来源而不提前抽样。
  return $sformatf({"rdma.qp.type=%s depth=%0d mtu=%0d max_sge=%0d dest_qpn=%0d; ",
    "rdma.pkt.smac=%012h dmac=%012h; rdma.traffic.op=%s count=%0d len=%s sge=%s ",
    "data_fixed=%s data_pattern=%s imm=%s"},
    qp.kind.name(), qp.depth, qp.mtu, qp.max_sge, qp.dest_qpn, pkt.src_mac, pkt.dst_mac,
    traffic.op, traffic.count, traffic.len, traffic.sge, traffic.data_fixed,
    traffic.data_pattern, traffic.imm);
endfunction
