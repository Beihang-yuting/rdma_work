// 目录：外部适配器实现层 adapters/aip/rdma_aip_cfg_pkg.sv。
// 层：外部适配器（参数）。
// 职责：把 aip_core 的命令行参数能力接到 rdma_env_cfg：
//   - rdma_aip_cfg_loader：读取 +rdma.env.*（模式、链路、序列、时间、检查开关）、
//     +rdma.{qp,mem,pkt,traffic}.*，写入配置与统一场景；
//   - rdma_aip_value_spec：业务流量分布表达式求值器，在默认语法（定值、[lo:hi]、候选列表）之外
//     支持 aip_core 的权重 {..}/(..)、inc:/dec:、rand 等语法。
//   参数只写配置对象，env、agent、序列不感知 aip_core；build 与运行期候选共用读取；项目决定原子提交。
// 依赖：aip_core_pkg（AIP_CORE_ROOT 指定的外部组件，须是本编译单元首个 AIP 文件）、rdma_env_pkg。
// 所有权：加载器为静态工具类，不持有状态；求值器对象交给配置持有。
// 生命周期：build 或重载读取独立候选；不注册命令、不拥有平台资源。
package rdma_aip_cfg_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import aip_core_pkg::*;
  import rdma_types_pkg::*;
  import rdma_env_pkg::*;

  // 设计说明：先用 env 包的默认语法求值（不消耗额外诊断上下文），失败时交给 aip_core 的解析器；
  //   aip_core 对非法表达式直接 FATAL 并给出原始输入，参数错误不会被静默降级。
  class rdma_aip_value_spec extends rdma_value_spec;
    `uvm_object_utils(rdma_aip_value_spec)

    // 功能：构造 aip_core 语法的分布表达式求值器。
    // 输入/输出及副作用：name 为 UVM 名；无状态。
    // 失败/边界：构造不校验表达式。
    extern function new(string	name = "rdma_aip_value_spec");

    // 功能：对表达式求值；顶层逗号列表随机选一项后再求值，默认语法不认识的单项交给
    //   aip_cmdline#(longint unsigned)::parse_value（权重、inc/dec、rand 等）。
    // 输入/输出及副作用：spec 为表达式，value 输出抽到的值，why 输出失败原因；消耗随机数。
    // 失败/边界：完整字面量或区间端点溢出返回 0，绝不回退；其它非法语法由 aip_core FATAL，成功返回抽样值。
    extern virtual function bit eval(string	spec, output longint unsigned	value, output string	why);
  endclass

    // 功能：构造 aip_core 语法的分布表达式求值器。
    // 输入/输出及副作用：name 为 UVM 名；无状态。
    // 失败/边界：构造不校验表达式。
function rdma_aip_value_spec::new(string	name = "rdma_aip_value_spec");
      super.new(name);
endfunction

    // 功能：对表达式求值；顶层逗号列表随机选一项后再求值，默认语法不认识的单项交给
    //   aip_cmdline#(longint unsigned)::parse_value（权重、inc/dec、rand 等）。
    // 输入/输出及副作用：spec 为表达式，value 输出抽到的值，why 输出失败原因；消耗随机数。
    // 失败/边界：完整字面量或区间端点溢出返回 0，绝不回退；其它非法语法由 aip_core FATAL，成功返回抽样值。
function bit rdma_aip_value_spec::eval(string	spec, output longint unsigned	value, output string	why);
      string	parts[$];

      split_top(strip(spec), parts);
      if (parts.size() > 1)
        return eval(parts[$urandom_range(parts.size() - 1, 0)], value, why);
      if (super.eval(spec, value, why))
        return 1'b1;
      if (why == "numeric literal exceeds 64-bit range")
        return 0;
      value = aip_cmdline#(longint	unsigned)::parse_value(strip(spec));
      why = "";
      return 1'b1;
endfunction

  // 参数适配器只读取 rdma.*；项目协调候选校验/提交，不在这里注册重载命令。
  class rdma_aip_cfg_loader;
  // 功能：以构建与重载共用读取入口填充未发布配置。
  // 输入/输出及副作用：cfg 是候选或 build 配置，vseq_type 输入默认/输出选择；安装 AIP WR 求值器。
  // 失败/边界：返回语义错误状态；AIP 标量语法错误仍 fatal；调用方不得传入正在使用的活动配置。
    extern static function rdma_status load(rdma_env_cfg	cfg, inout string	vseq_type);

  // 功能：从新默认值读取运行期候选，固定环境字段继承活动默认值。
  // 输入/输出及副作用：active 借用；candidate 输出独立数据对象；重复执行宏，无资源分配或 WR 抽样。
  // 失败/边界：空 active 返回 INVALID_ARGUMENT；不因 finalized 缓存返回；typed 错误仅影响候选。
    extern static function rdma_status make_runtime_candidate(rdma_env_cfg	active, output rdma_env_cfg	candidate);

  // 功能：读取固定环境字段与轮询/响应时间，队列参数只存在于 rdma.qp。
  // 输入/输出及副作用：cfg 作为默认值并接收读取结果。
  // 失败/边界：未知 mode 写入非法枚举供核心状态校验；语法错误由 AIP fatal。
    extern static function void load_env(rdma_env_cfg	cfg);

  // 功能：读取队列深度、MTU、SGE、PSN、QKey 与重试编码，并把 type 文本映射为传输枚举。
  // 输入/输出及副作用：b 接收 AIP 宏结果；默认值取未发布候选当前字段。
  // 失败/边界：标量范围由核心 validate 返回错误；AIP 数字语法或类型转换错误仍 fatal。
    extern static function void load_qp(rdma_scenario_cfg	b);

  // 功能：读取缓冲/槽大小、槽数、MR 偏移及远端三类访问权限。
  // 输入/输出及副作用：b 接收 AIP 宏结果；默认值取未发布候选当前字段。
  // 失败/边界：标量范围由核心 validate 返回错误；AIP 数字语法或类型转换错误仍 fatal。
    extern static function void load_mem(rdma_scenario_cfg	b);

  // 功能：读取操作选择、七种权重、消息数/方向/signaled 比例，并保留长度/SGE/模式表达式原文。
  // 输入/输出及副作用：b 接收 AIP 宏结果；默认值取未发布候选当前字段。
  // 失败/边界：标量范围由核心 validate 返回错误；AIP 数字语法或类型转换错误仍 fatal。
    extern static function void load_traffic(rdma_scenario_cfg	b);

  // 功能：读取报文属性，保留 VLAN/UDP 全宽供范围校验。
  // 输入/输出及副作用：b 接收五个 pkt 字段；IPv4 支持既有点分或 AIP 数字语法。
  // 失败/边界：点分语义错误返回状态；数值语法错误继承 AIP fatal。
    extern static function rdma_status load_pkt(rdma_scenario_cfg	b);

  // 功能：解析既有 IPv4 点分文本或 AIP 数字，拒绝非法 octet。
  // 输入/输出及副作用：name 为 pkt 子键，ip 输入默认值/输出解析值；只修改候选。
  // 失败/边界：空显式值置零；段数不是4或 octet>255 返回 INVALID_ARGUMENT；不回退掩盖错误。
    extern static function rdma_status ip_param(string	name, inout bit [31:0]	ip);

  // 功能：保留 WR 表达式原文及显式空 override，遵守 AIP full/leaf 优先级。
  // 输入/输出及副作用：path/name 指定参数；fallback 仅在缺失值时使用；不解析、不消耗随机数。
  // 失败/边界：aip_string 会抽取逗号候选，因此此处复用现有原文查询；空 override 不回退默认。
    extern static function string raw_or(string	path, string	name, string	fallback);

  endclass

  // 功能：以构建与重载共用读取入口填充未发布配置。
  // 输入/输出及副作用：cfg 是候选或 build 配置，vseq_type 输入默认/输出选择；安装 AIP WR 求值器。
  // 失败/边界：返回语义错误状态；AIP 标量语法错误仍 fatal；调用方不得传入正在使用的活动配置。
  function rdma_status rdma_aip_cfg_loader::load(rdma_env_cfg	cfg, inout string	vseq_type);
    rdma_status	status;
    cfg.vseq_type = vseq_type;
    load_env(cfg);
    load_qp(cfg.scenario);
    load_mem(cfg.scenario);
    status = load_pkt(cfg.scenario);
    if (!status.ok())
      return status;
    load_traffic(cfg.scenario);
    cfg.spec = rdma_aip_value_spec::type_id::create("aip_value_spec");
    vseq_type = cfg.vseq_type;
    return cfg.validate_runtime_candidate(cfg);
  endfunction

  // 功能：从新默认值读取运行期候选，固定环境字段继承活动默认值。
  // 输入/输出及副作用：active 借用；candidate 输出独立数据对象；重复执行宏，无资源分配或 WR 抽样。
  // 失败/边界：空 active 返回 INVALID_ARGUMENT；不因 finalized 缓存返回；typed 错误仅影响候选。
  function rdma_status rdma_aip_cfg_loader::make_runtime_candidate(rdma_env_cfg	active, output rdma_env_cfg	candidate);
    string	vseq;
    if (active == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "active RDMA configuration is missing");
    candidate = rdma_env_cfg::type_id::create("rdma_candidate");
    candidate.inherit_identity(active);
    vseq = active.vseq_type;
    return load(candidate, vseq);
  endfunction

  // 功能：读取固定环境字段与轮询/响应时间，队列参数只存在于 rdma.qp。
  // 输入/输出及副作用：cfg 作为默认值并接收读取结果。
  // 失败/边界：未知 mode 写入非法枚举供核心状态校验；语法错误由 AIP fatal。
  function void rdma_aip_cfg_loader::load_env(rdma_env_cfg	cfg);
    string	mode;
    string	link_type;
    string	vseq;
    int unsigned	poll_ns;
    int unsigned	response_timeout_us;
    bit	checker_enable;
    bit	cov_enable;

    mode = cfg.mode.name();
    link_type = cfg.link_type;
    vseq = cfg.vseq_type;
    poll_ns = cfg.poll_interval / 1ns;
    response_timeout_us = cfg.response_timeout / 1us;
    checker_enable = cfg.checker_enable;
    cov_enable = cfg.cov_enable;
    `aip_string("rdma.env", mode, mode)
    `aip_string("rdma.env", link_type, link_type)
    `aip_string("rdma.env", vseq, vseq)
    `aip_int("rdma.env", int	unsigned, poll_ns, poll_ns)
    `aip_int("rdma.env", int	unsigned, response_timeout_us, response_timeout_us)
    `aip_int("rdma.env", bit, checker_enable, checker_enable)
    `aip_int("rdma.env", bit, cov_enable, cov_enable)
    case (mode.toupper())
      "PEER", "RDMA_ENV_MODE_PEER": cfg.mode = RDMA_ENV_MODE_PEER;
      "RXE", "RDMA_ENV_MODE_RXE": cfg.mode = RDMA_ENV_MODE_RXE;
      "DUT", "RDMA_ENV_MODE_DUT": cfg.mode = RDMA_ENV_MODE_DUT;
      default: cfg.mode = rdma_env_mode_e'(-1);
    endcase
    cfg.link_type = link_type;
    cfg.vseq_type = vseq;
    cfg.poll_interval = poll_ns * 1ns;
    cfg.response_timeout = response_timeout_us * 1us;
    cfg.checker_enable = checker_enable;
    cfg.cov_enable = cov_enable;
  endfunction

  // 功能：读取队列深度、MTU、SGE、PSN、QKey 与重试编码，并把 type 文本映射为传输枚举。
  // 输入/输出及副作用：b 接收 AIP 宏结果；默认值取未发布候选当前字段。
  // 失败/边界：标量范围由核心 validate 返回错误；AIP 数字语法或类型转换错误仍 fatal。
  function void rdma_aip_cfg_loader::load_qp(rdma_scenario_cfg	b);
    int unsigned	depth;
    int unsigned	mtu;
    int unsigned	max_sge;
    int unsigned	psn;
    bit [31:0]	qkey;
    int	timeout;
    int	retry;
    int	rnr_retry;
    int	min_rnr;
    string	kind;

    depth = b.qp.depth;
    mtu = b.qp.mtu;
    max_sge = b.qp.max_sge;
    psn = b.qp.psn;
    qkey = b.qp.qkey;
    timeout = b.qp.timeout;
    retry = b.qp.retry;
    rnr_retry = b.qp.rnr_retry;
    min_rnr = b.qp.min_rnr;
    `aip_int("rdma.qp", int	unsigned, depth, depth)
    `aip_int("rdma.qp", int	unsigned, mtu, mtu)
    `aip_int("rdma.qp", int	unsigned, max_sge, max_sge)
    `aip_int("rdma.qp", int	unsigned, psn, psn)
    `aip_int("rdma.qp", bit [31:0], qkey, qkey)
    `aip_int("rdma.qp", int, timeout, timeout)
    `aip_int("rdma.qp", int, retry, retry)
    `aip_int("rdma.qp", int, rnr_retry, rnr_retry)
    `aip_int("rdma.qp", int, min_rnr, min_rnr)
    b.qp.depth = depth;
    b.qp.mtu = mtu;
    b.qp.max_sge = max_sge;
    b.qp.psn = psn;
    b.qp.qkey = qkey;
    b.qp.timeout = timeout;
    b.qp.retry = retry;
    b.qp.rnr_retry = rnr_retry;
    b.qp.min_rnr = min_rnr;
    case (b.qp.kind)
      RDMA_SCENARIO_RC: kind = "RC";
      RDMA_SCENARIO_UD: kind = "UD";
      RDMA_SCENARIO_URC: kind = "URC";
      default: kind = "";
    endcase
    // type 是 SV 保留字，不能作为宏的同名局部变量；使用 aip_string 的现有底层入口。
    aip_cmdline#(string)::get_single_value("type", "rdma.qp", kind, kind, `__FILE__, `__LINE__);
    case (kind.toupper())
      "RC": b.qp.kind = RDMA_SCENARIO_RC;
      "UD": b.qp.kind = RDMA_SCENARIO_UD;
      "URC": b.qp.kind = RDMA_SCENARIO_URC;
      default: b.qp.kind = rdma_scenario_type_e'(-1);
    endcase

  endfunction

  // 功能：读取缓冲/槽大小、槽数、MR 偏移及远端三类访问权限。
  // 输入/输出及副作用：b 接收 AIP 宏结果；默认值取未发布候选当前字段。
  // 失败/边界：标量范围由核心 validate 返回错误；AIP 数字语法或类型转换错误仍 fatal。
  function void rdma_aip_cfg_loader::load_mem(rdma_scenario_cfg	b);
    int unsigned	buf_bytes;
    int unsigned	slot_bytes;
    int unsigned	slots;
    int unsigned	mr_offset;
    bit	mr_remote_read;
    bit	mr_remote_write;
    bit	mr_remote_atomic;

    buf_bytes = b.mem.buf_bytes;
    slot_bytes = b.mem.slot_bytes;
    slots = b.mem.slots;
    mr_offset = b.mem.mr_offset;
    mr_remote_read = b.mem.mr_remote_read;
    mr_remote_write = b.mem.mr_remote_write;
    mr_remote_atomic = b.mem.mr_remote_atomic;
    `aip_int("rdma.mem", int	unsigned, buf_bytes, buf_bytes)
    `aip_int("rdma.mem", int	unsigned, slot_bytes, slot_bytes)
    `aip_int("rdma.mem", int	unsigned, slots, slots)
    `aip_int("rdma.mem", int	unsigned, mr_offset, mr_offset)
    `aip_int("rdma.mem", bit, mr_remote_read, mr_remote_read)
    `aip_int("rdma.mem", bit, mr_remote_write, mr_remote_write)
    `aip_int("rdma.mem", bit, mr_remote_atomic, mr_remote_atomic)
    b.mem.buf_bytes = buf_bytes;
    b.mem.slot_bytes = slot_bytes;
    b.mem.slots = slots;
    b.mem.mr_offset = mr_offset;
    b.mem.mr_remote_read = mr_remote_read;
    b.mem.mr_remote_write = mr_remote_write;
    b.mem.mr_remote_atomic = mr_remote_atomic;

  endfunction

  // 功能：读取操作选择、七种权重、消息数/方向/signaled 比例，并保留长度/SGE/模式表达式原文。
  // 输入/输出及副作用：b 接收 AIP 宏结果；默认值取未发布候选当前字段。
  // 失败/边界：标量范围由核心 validate 返回错误；AIP 数字语法或类型转换错误仍 fatal。
  function void rdma_aip_cfg_loader::load_traffic(rdma_scenario_cfg	b);
    int unsigned	count;
    int unsigned	w_send;
    int unsigned	w_send_imm;
    int unsigned	w_write;
    int unsigned	w_write_imm;
    int unsigned	w_read;
    int unsigned	w_cas;
    int unsigned	w_faa;
    int unsigned	signaled_pct;
    int unsigned	dir;
    string	op;

    count = b.traffic.count;
    w_send = b.traffic.w_send;
    w_send_imm = b.traffic.w_send_imm;
    w_write = b.traffic.w_write;
    w_write_imm = b.traffic.w_write_imm;
    w_read = b.traffic.w_read;
    w_cas = b.traffic.w_cas;
    w_faa = b.traffic.w_faa;
    signaled_pct = b.traffic.signaled_pct;
    dir = b.traffic.dir;
    op = b.traffic.op;
    `aip_int("rdma.traffic", int	unsigned, count, count)
    `aip_int("rdma.traffic", int	unsigned, w_send, w_send)
    `aip_int("rdma.traffic", int	unsigned, w_send_imm, w_send_imm)
    `aip_int("rdma.traffic", int	unsigned, w_write, w_write)
    `aip_int("rdma.traffic", int	unsigned, w_write_imm, w_write_imm)
    `aip_int("rdma.traffic", int	unsigned, w_read, w_read)
    `aip_int("rdma.traffic", int	unsigned, w_cas, w_cas)
    `aip_int("rdma.traffic", int	unsigned, w_faa, w_faa)
    `aip_int("rdma.traffic", int	unsigned, signaled_pct, signaled_pct)
    `aip_int("rdma.traffic", int	unsigned, dir, dir)
    `aip_string("rdma.traffic", op, op)
    b.traffic.count = count;
    b.traffic.w_send = w_send;
    b.traffic.w_send_imm = w_send_imm;
    b.traffic.w_write = w_write;
    b.traffic.w_write_imm = w_write_imm;
    b.traffic.w_read = w_read;
    b.traffic.w_cas = w_cas;
    b.traffic.w_faa = w_faa;
    b.traffic.signaled_pct = signaled_pct;
    b.traffic.dir = dir;
    b.traffic.op = op;
    b.traffic.len = raw_or("rdma.traffic", "len", b.traffic.len);
    b.traffic.sge = raw_or("rdma.traffic", "sge", b.traffic.sge);
    b.traffic.data_mode = raw_or("rdma.traffic", "data_mode", b.traffic.data_mode);

  endfunction

  // 功能：读取报文属性，保留 VLAN/UDP 全宽供范围校验。
  // 输入/输出及副作用：b 接收五个 pkt 字段；IPv4 支持既有点分或 AIP 数字语法。
  // 失败/边界：点分语义错误返回状态；数值语法错误继承 AIP fatal。
  function rdma_status rdma_aip_cfg_loader::load_pkt(rdma_scenario_cfg	b);
    bit	vlan_en;
    int unsigned	vlan_id;
    int unsigned	udp_sport;
    rdma_status	status;
    vlan_en = b.pkt.vlan_en;
    vlan_id = b.pkt.vlan_id;
    udp_sport = b.pkt.udp_sport;
    `aip_int("rdma.pkt", bit, vlan_en, vlan_en)
    `aip_int("rdma.pkt", int	unsigned, vlan_id, vlan_id)
    `aip_int("rdma.pkt", int	unsigned, udp_sport, udp_sport)
    b.pkt.vlan_en = vlan_en;
    b.pkt.vlan_id = vlan_id;
    b.pkt.udp_sport = udp_sport;
    status = ip_param("src_ip", b.pkt.src_ip);
    if (!status.ok())
      return status;
    return ip_param("dst_ip", b.pkt.dst_ip);
  endfunction

  // 功能：解析既有 IPv4 点分文本或 AIP 数字，拒绝非法 octet。
  // 输入/输出及副作用：name 为 pkt 子键，ip 输入默认值/输出解析值；只修改候选。
  // 失败/边界：空显式值置零；段数不是4或 octet>255 返回 INVALID_ARGUMENT；不回退掩盖错误。
  function rdma_status rdma_aip_cfg_loader::ip_param(string	name, inout bit [31:0]	ip);
    string	raw;
    string	parts[$];
    string	cur;
    bit	dotted;
    bit [31:0]	value;
    longint unsigned	octet;
    bit	number_overflow;
    raw = raw_or("rdma.pkt", name, $sformatf("0x%08h", ip));
    dotted = 0;
    foreach (raw[i])
      if (raw[i] == ".")
        dotted = 1;
    if (!dotted) begin
      ip = raw == "" ? 0 : aip_cmdline#(bit [31:0])::parse_value(raw);
      return rdma_status::success();
    end
    cur = "";
    foreach (raw[i]) begin
      if (raw[i] == ".") begin
        parts.push_back(cur);
        cur = "";
      end
      else
        cur = {cur, string'(raw[i])};
    end
    parts.push_back(cur);
    if (parts.size() != 4)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, {"rdma.pkt.", name, " requires four IPv4 octets"});
    value = 0;
    foreach (parts[i]) begin
      if (!rdma_value_spec::parse_number(parts[i], octet, number_overflow) || octet > 255)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, {"rdma.pkt.", name, " IPv4 octet outside 0..255"});
      value = {value[23:0], octet[7:0]};
    end
    ip = value;
    return rdma_status::success();
  endfunction

  // 功能：保留 WR 表达式原文及显式空 override，遵守 AIP full/leaf 优先级。
  // 输入/输出及副作用：path/name 指定参数；fallback 仅在缺失值时使用；不解析、不消耗随机数。
  // 失败/边界：aip_string 会抽取逗号候选，因此此处复用现有原文查询；空 override 不回退默认。
  function string rdma_aip_cfg_loader::raw_or(string	path, string	name, string	fallback);
    string	raw;
    if (aip_cmdline#(string)::lookup_override(name, path, raw))
      return rdma_value_spec::strip(raw);
    raw = rdma_value_spec::strip(aip_cmdline#(string)::get_cmdline_string(name, path));
    return raw == "" ? fallback : raw;
  endfunction

endpackage
