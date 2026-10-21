// 目录：外部适配器实现层 adapters/aip/rdma_aip_cfg_pkg.sv。
// 层：外部适配器（参数）。
// 职责：把 aip_core 的命令行参数能力接到 rdma_env_cfg：
//   - rdma_aip_cfg_loader：读取 +rdma.env.*（模式、链路、序列、QP 环境默认、时间、检查开关）、
//     +rdma.biz.en（启用的业务）与 +rdma.biz.<业务>.{qp,mem,pkt,trf}.*，写入配置与业务模板；
//   - rdma_aip_value_spec：业务流量分布表达式求值器，在默认语法（定值、[lo:hi]、候选列表）之外
//     支持 aip_core 的权重 {..}/(..)、inc:/dec:、rand 等语法。
//   参数只写配置对象，env、agent、序列不感知 aip_core；读取在测试 build 阶段一次完成。
// 依赖：aip_core_pkg（AIP_CORE_ROOT 指定的外部组件，须是本编译单元首个 AIP 文件）、rdma_env_pkg。
// 所有权：加载器为静态工具类，不持有状态；求值器对象交给配置持有。
// 生命周期：测试 build_phase 调用 load；之后配置由 env finalize 并冻结。
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
    function new(string name = "rdma_aip_value_spec");
      super.new(name);
    endfunction

    // 功能：对表达式求值；顶层逗号列表随机选一项后再求值，默认语法不认识的单项交给
    //   aip_cmdline#(longint unsigned)::parse_value（权重、inc/dec、rand 等）。
    // 输入/输出及副作用：spec 为表达式，value 输出抽到的值，why 输出失败原因；消耗随机数。
    // 失败/边界：aip_core 对非法语法直接 FATAL 终止仿真，因此本函数只在默认语法成功或 aip 解析成功时返回。
    virtual function bit eval(string spec, output longint unsigned value, output string why);
      string parts[$];

      split_top(strip(spec), parts);
      if (parts.size() > 1)
        return eval(parts[$urandom_range(parts.size() - 1, 0)], value, why);
      if (super.eval(spec, value, why))
        return 1'b1;
      value = aip_cmdline#(longint unsigned)::parse_value(strip(spec));
      why = "";
      return 1'b1;
    endfunction
  endclass

  // 设计说明：aip_core 的标量宏以变量名作为参数名（`"name`），因此每个字段先拷到同名局部变量，
  //   以当前配置值作为默认值调用宏，再写回配置；未传参数时值保持不变（测试 configure() 的设置仍有效）。
  class rdma_aip_cfg_loader;
    // 功能：加载全部 rdma 参数：环境级、启用业务列表、每个业务模板，并安装 aip 表达式求值器。
    // 输入/输出及副作用：cfg 为测试已 configure 的配置；vseq_type 为测试当前序列名（输入输出）。
    //   修改配置与模板字段；aip_core 按其打印控制输出注册日志。
    // 失败/边界：非法参数由 aip_core FATAL；未知模式名、未知业务名、非法 IPv4 文本 uvm_error。
    static function void load(rdma_env_cfg cfg, inout string vseq_type);
      rdma_aip_value_spec ev;

      load_env(cfg, vseq_type);
      load_biz_list(cfg);
      foreach (cfg.biz[i])
        load_biz(cfg.biz[i]);
      ev = rdma_aip_value_spec::type_id::create("aip_value_spec");
      cfg.spec = ev;
    endfunction

    // 功能：读取 +rdma.env.*：mode（PEER/RXE/DUT）、link_type、vseq、qp_depth、mtu、timeout、retry、
    //   rnr_retry、min_rnr、ud_qkey、poll_ns、response_timeout_us、checker_enable、cov_enable。
    // 输入/输出及副作用：写回 cfg 与 vseq_type；默认值取当前配置。
    // 失败/边界：mode 名不是 PEER/RXE/DUT（或带 RDMA_ENV_MODE_ 前缀）时 uvm_error 并保持原值。
    static function void load_env(rdma_env_cfg cfg, inout string vseq_type);
      string mode;
      string link_type;
      string vseq;
      int unsigned qp_depth;
      int unsigned mtu;
      int unsigned timeout;
      int unsigned retry;
      int unsigned rnr_retry;
      int unsigned min_rnr;
      bit [31:0] ud_qkey;
      int unsigned poll_ns;
      int unsigned response_timeout_us;
      bit checker_enable;
      bit cov_enable;

      mode = cfg.mode.name();
      link_type = cfg.link_type;
      vseq = vseq_type;
      qp_depth = cfg.qp_depth;
      mtu = cfg.mtu;
      timeout = cfg.timeout;
      retry = cfg.retry;
      rnr_retry = cfg.rnr_retry;
      min_rnr = cfg.min_rnr;
      ud_qkey = cfg.ud_qkey;
      poll_ns = cfg.poll_interval / 1ns;
      response_timeout_us = cfg.response_timeout / 1us;
      checker_enable = cfg.checker_enable;
      cov_enable = cfg.cov_enable;
      `aip_string("rdma.env", mode, mode)
      `aip_string("rdma.env", link_type, link_type)
      `aip_string("rdma.env", vseq, vseq)
      `aip_int("rdma.env", int unsigned, qp_depth, qp_depth)
      `aip_int("rdma.env", int unsigned, mtu, mtu)
      `aip_int("rdma.env", int unsigned, timeout, timeout)
      `aip_int("rdma.env", int unsigned, retry, retry)
      `aip_int("rdma.env", int unsigned, rnr_retry, rnr_retry)
      `aip_int("rdma.env", int unsigned, min_rnr, min_rnr)
      `aip_int("rdma.env", bit [31:0], ud_qkey, ud_qkey)
      `aip_int("rdma.env", int unsigned, poll_ns, poll_ns)
      `aip_int("rdma.env", int unsigned, response_timeout_us, response_timeout_us)
      `aip_int("rdma.env", bit, checker_enable, checker_enable)
      `aip_int("rdma.env", bit, cov_enable, cov_enable)
      cfg.mode = mode_of(mode, cfg.mode);
      cfg.link_type = link_type;
      vseq_type = vseq;
      cfg.qp_depth = qp_depth;
      cfg.mtu = mtu;
      cfg.timeout = timeout;
      cfg.retry = retry;
      cfg.rnr_retry = rnr_retry;
      cfg.min_rnr = min_rnr;
      cfg.ud_qkey = ud_qkey;
      cfg.poll_interval = poll_ns * 1ns;
      cfg.response_timeout = response_timeout_us * 1us;
      cfg.checker_enable = checker_enable;
      cfg.cov_enable = cov_enable;
    endfunction

    // 功能：把模式名（PEER/RXE/DUT，大小写不敏感，可带 RDMA_ENV_MODE_ 前缀）转换为枚举。
    // 输入/输出及副作用：name 为输入，fallback 为无法识别时返回的原值；纯转换。
    // 失败/边界：未知名字 uvm_error 并返回 fallback。
    static function rdma_env_mode_e mode_of(string name, rdma_env_mode_e fallback);
      string n;

      n = name.toupper();
      if (n == "PEER" || n == "RDMA_ENV_MODE_PEER")
        return RDMA_ENV_MODE_PEER;
      if (n == "RXE" || n == "RDMA_ENV_MODE_RXE")
        return RDMA_ENV_MODE_RXE;
      if (n == "DUT" || n == "RDMA_ENV_MODE_DUT")
        return RDMA_ENV_MODE_DUT;
      `uvm_error("RDMA_AIP", {"unknown +rdma.env.mode: ", name})
      return fallback;
    endfunction

    // 功能：读取 +rdma.biz.en=<业务名列表>，只启用列出的业务；未给出时保持全部启用。
    // 输入/输出及副作用：修改模板 enable。
    // 失败/边界：未知业务名由 cfg.enable_biz 报 uvm_error。
    static function void load_biz_list(rdma_env_cfg cfg);
      string en[];
      string names[$];

      `aip_str_list("rdma.biz", en, "")
      if (en.size() == 0)
        return;
      foreach (en[i])
        names.push_back(en[i]);
      cfg.enable_biz(names);
    endfunction

    // 功能：读取一个业务模板的全部字段：+rdma.biz.<业务>.enable、.qp.*、.mem.*、.pkt.*、.trf.*。
    //   分布类字段（trf.len、trf.sge、trf.data_mode）按原始字符串保存，每条消息再求值。
    // 输入/输出及副作用：修改模板字段；默认值取模板当前值。
    // 失败/边界：数值语法错误由 aip_core FATAL；IPv4 点分文本非法时 uvm_error 并保持原值。
    static function void load_biz(rdma_biz_cfg b);
      string root;
      bit enable;

      root = {"rdma.biz.", b.biz_name()};
      enable = b.enable;
      `aip_int(root, bit, enable, enable)
      b.enable = enable;
      load_qp(b, {root, ".qp"});
      load_mem(b, {root, ".mem"});
      load_pkt(b, {root, ".pkt"});
      load_trf(b, {root, ".trf"});
    endfunction

    // 功能：读取 QP 参数：depth、mtu、max_sge、psn（24 位，rand 即 24 位均匀）、qkey、timeout、retry、
    //   rnr_retry、min_rnr（-1 表示继承环境默认，未给出时保持模板值）。
    // 输入/输出及副作用：path 为 rdma.biz.<业务>.qp；修改 b.qp。
    // 失败/边界：数值语法错误由 aip_core FATAL；范围约束在 finalize 校验。
    static function void load_qp(rdma_biz_cfg b, string path);
      int unsigned depth;
      int unsigned mtu;
      int unsigned max_sge;
      bit [23:0] psn;
      bit [31:0] qkey;
      int timeout;
      int retry;
      int rnr_retry;
      int min_rnr;

      depth = b.qp.depth;
      mtu = b.qp.mtu;
      max_sge = b.qp.max_sge;
      psn = b.qp.psn;
      qkey = b.qp.qkey;
      timeout = b.qp.timeout;
      retry = b.qp.retry;
      rnr_retry = b.qp.rnr_retry;
      min_rnr = b.qp.min_rnr;
      `aip_int(path, int unsigned, depth, depth)
      `aip_int(path, int unsigned, mtu, mtu)
      `aip_int(path, int unsigned, max_sge, max_sge)
      `aip_int(path, bit [23:0], psn, psn)
      `aip_int(path, bit [31:0], qkey, qkey)
      `aip_int(path, int, timeout, timeout)
      `aip_int(path, int, retry, retry)
      `aip_int(path, int, rnr_retry, rnr_retry)
      `aip_int(path, int, min_rnr, min_rnr)
      b.qp.depth = depth;
      b.qp.mtu = mtu;
      b.qp.max_sge = max_sge;
      b.qp.psn = psn;
      b.qp.qkey = qkey;
      b.qp.timeout = timeout;
      b.qp.retry = retry;
      b.qp.rnr_retry = rnr_retry;
      b.qp.min_rnr = min_rnr;
    endfunction

    // 功能：读取内存参数：buf_bytes、slot_bytes、slots、mr_offset、mr_remote_read/write/atomic。
    // 输入/输出及副作用：path 为 rdma.biz.<业务>.mem；修改 b.mem。
    // 失败/边界：数值语法错误由 aip_core FATAL；容量关系在 finalize 校验。
    static function void load_mem(rdma_biz_cfg b, string path);
      int unsigned buf_bytes;
      int unsigned slot_bytes;
      int unsigned slots;
      int unsigned mr_offset;
      bit mr_remote_read;
      bit mr_remote_write;
      bit mr_remote_atomic;

      buf_bytes = b.mem.buf_bytes;
      slot_bytes = b.mem.slot_bytes;
      slots = b.mem.slots;
      mr_offset = b.mem.mr_offset;
      mr_remote_read = b.mem.mr_remote_read;
      mr_remote_write = b.mem.mr_remote_write;
      mr_remote_atomic = b.mem.mr_remote_atomic;
      `aip_int(path, int unsigned, buf_bytes, buf_bytes)
      `aip_int(path, int unsigned, slot_bytes, slot_bytes)
      `aip_int(path, int unsigned, slots, slots)
      `aip_int(path, int unsigned, mr_offset, mr_offset)
      `aip_int(path, bit, mr_remote_read, mr_remote_read)
      `aip_int(path, bit, mr_remote_write, mr_remote_write)
      `aip_int(path, bit, mr_remote_atomic, mr_remote_atomic)
      b.mem.buf_bytes = buf_bytes;
      b.mem.slot_bytes = slot_bytes;
      b.mem.slots = slots;
      b.mem.mr_offset = mr_offset;
      b.mem.mr_remote_read = mr_remote_read;
      b.mem.mr_remote_write = mr_remote_write;
      b.mem.mr_remote_atomic = mr_remote_atomic;
    endfunction

    // 功能：读取报文属性：vlan_en、vlan_id（12 位）、src_ip/dst_ip（点分 IPv4 或数值）、udp_sport（16 位）。
    // 输入/输出及副作用：path 为 rdma.biz.<业务>.pkt；修改 b.pkt。
    // 失败/边界：IPv4 点分文本非法时 uvm_error 并保持原值；数值语法错误由 aip_core FATAL。
    static function void load_pkt(rdma_biz_cfg b, string path);
      bit vlan_en;
      bit [11:0] vlan_id;
      bit [15:0] udp_sport;

      vlan_en = b.pkt.vlan_en;
      vlan_id = b.pkt.vlan_id;
      udp_sport = b.pkt.udp_sport;
      `aip_int(path, bit, vlan_en, vlan_en)
      `aip_int(path, bit [11:0], vlan_id, vlan_id)
      `aip_int(path, bit [15:0], udp_sport, udp_sport)
      b.pkt.vlan_en = vlan_en;
      b.pkt.vlan_id = vlan_id;
      b.pkt.udp_sport = udp_sport;
      b.pkt.src_ip = ip_param(path, "src_ip", b.pkt.src_ip);
      b.pkt.dst_ip = ip_param(path, "dst_ip", b.pkt.dst_ip);
    endfunction

    // 功能：读取一个 IPv4 参数：点分文本（如 10.0.0.5）自行解析，其余交给 aip_core 数值语法。
    // 输入/输出及副作用：path/name 组成参数键，fallback 为未给出或非法时的返回值。
    // 失败/边界：点分文本不是四段 0~255 时 uvm_error 并返回 fallback。
    static function bit [31:0] ip_param(string path, string name, bit [31:0] fallback);
      string raw;
      string parts[$];
      bit [31:0] ip;
      longint unsigned octet;

      raw = rdma_value_spec::strip(aip_cmdline#(string)::get_cmdline_string(name, path));
      if (raw == "")
        return fallback;
      if (!has_dot(raw))
        return aip_cmdline#(bit [31:0])::parse_value(raw);
      split_dots(raw, parts);
      ip = '0;
      if (parts.size() != 4) begin
        `uvm_error("RDMA_AIP", $sformatf("+%s.%s: invalid IPv4 '%s'", path, name, raw))
        return fallback;
      end
      foreach (parts[i]) begin
        if (!rdma_value_spec::parse_number(parts[i], octet) || octet > 255) begin
          `uvm_error("RDMA_AIP", $sformatf("+%s.%s: invalid IPv4 '%s'", path, name, raw))
          return fallback;
        end
        ip = {ip[23:0], octet[7:0]};
      end
      return ip;
    endfunction

    // 功能：判断字符串是否含有点号。
    // 输入/输出及副作用：纯查询。
    // 失败/边界：空串返回 0。
    static function bit has_dot(string s);
      foreach (s[i])
        if (s[i] == ".")
          return 1'b1;
      return 1'b0;
    endfunction

    // 功能：按点号拆分字符串。
    // 输入/输出及副作用：s 为输入，parts 输出各段（含空段）。
    // 失败/边界：不校验段内容，由调用者解析。
    static function void split_dots(string s, output string parts[$]);
      string cur;

      parts.delete();
      cur = "";
      foreach (s[i]) begin
        if (s[i] == ".") begin
          parts.push_back(cur);
          cur = "";
        end
        else
          cur = {cur, string'(s[i])};
      end
      parts.push_back(cur);
    endfunction

    // 功能：读取流量参数：count、w_send/w_send_imm/w_write/w_write_imm/w_read/w_cas/w_faa、signaled_pct、
    //   dir 为数值；len、sge、data_mode 为分布表达式原文（每条消息求值）。
    // 输入/输出及副作用：path 为 rdma.biz.<业务>.trf；修改 b.trf。
    // 失败/边界：数值语法错误由 aip_core FATAL；表达式在使用时求值，非法时 FATAL。
    static function void load_trf(rdma_biz_cfg b, string path);
      int unsigned count;
      int unsigned w_send;
      int unsigned w_send_imm;
      int unsigned w_write;
      int unsigned w_write_imm;
      int unsigned w_read;
      int unsigned w_cas;
      int unsigned w_faa;
      int unsigned signaled_pct;
      int unsigned dir;

      count = b.trf.count;
      w_send = b.trf.w_send;
      w_send_imm = b.trf.w_send_imm;
      w_write = b.trf.w_write;
      w_write_imm = b.trf.w_write_imm;
      w_read = b.trf.w_read;
      w_cas = b.trf.w_cas;
      w_faa = b.trf.w_faa;
      signaled_pct = b.trf.signaled_pct;
      dir = b.trf.dir;
      `aip_int(path, int unsigned, count, count)
      `aip_int(path, int unsigned, w_send, w_send)
      `aip_int(path, int unsigned, w_send_imm, w_send_imm)
      `aip_int(path, int unsigned, w_write, w_write)
      `aip_int(path, int unsigned, w_write_imm, w_write_imm)
      `aip_int(path, int unsigned, w_read, w_read)
      `aip_int(path, int unsigned, w_cas, w_cas)
      `aip_int(path, int unsigned, w_faa, w_faa)
      `aip_int(path, int unsigned, signaled_pct, signaled_pct)
      `aip_int(path, int unsigned, dir, dir)
      b.trf.count = count;
      b.trf.w_send = w_send;
      b.trf.w_send_imm = w_send_imm;
      b.trf.w_write = w_write;
      b.trf.w_write_imm = w_write_imm;
      b.trf.w_read = w_read;
      b.trf.w_cas = w_cas;
      b.trf.w_faa = w_faa;
      b.trf.signaled_pct = signaled_pct;
      b.trf.dir = dir;
      b.trf.len = raw_or(path, "len", b.trf.len);
      b.trf.sge = raw_or(path, "sge", b.trf.sge);
      b.trf.data_mode = raw_or(path, "data_mode", b.trf.data_mode);
    endfunction

    // 功能：读取参数原文（含 Tcl set_param 覆盖与无路径回退，规则同 aip_core），未给出时返回 fallback。
    // 输入/输出及副作用：path/name 组成参数键；纯读取。
    // 失败/边界：不解析内容；给出空值视为未给出。
    static function string raw_or(string path, string name, string fallback);
      string raw;

      raw = rdma_value_spec::strip(aip_cmdline#(string)::get_cmdline_string(name, path));
      return raw == "" ? fallback : raw;
    endfunction
  endclass
endpackage
