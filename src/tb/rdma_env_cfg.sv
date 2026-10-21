// 目录：验证组件层 tb/rdma_env_cfg.sv。
// 层：验证组件。
// 职责：env 配置根：运行模式、拓扑（dpu_common 的 Host/PF/VF 与 Function 角色）、链路类型、插件、
//   QP 环境默认属性、时间参数、检查开关，以及业务模板 biz（资源与流量参数的唯一配置源）。测试经
//   uvm_config_db 把它交给 env（键 "cfg"）。
// 依赖：rdma_dpu_adapter_pkg（Function 声明）、rdma_biz_cfg（业务模板与表达式求值器）。
// 所有权：配置对象持有插件引用、业务模板与表达式求值器。
// 生命周期：测试 build_phase 创建并加载参数；env build_phase 在插件 pre_build 之后调用 finalize
//   解析继承值、校验并冻结，之后各组件只读。

typedef class rdma_env;
typedef class rdma_dut_frame_endpoint;

// 一个 Function 的声明（交给 rdma_dpu_system）；role 决定设备由模型还是 RTL 承担。
typedef struct {
  int unsigned host;
  int unsigned pf;
  dpu_function_kind_e kind;
  int unsigned vf;
  rdma_func_role_e role;
} rdma_env_func_t;

// 传输相关扩展：PCIe 承载、rxe 远端等在各自包内实现。
virtual class rdma_env_plugin extends uvm_object;
  // 功能：构造不带资源与状态的 env 插件基对象，供具体传输扩展继承生命周期钩子。
  // 输入/输出及副作用：name 为 UVM 名；基类不保存 env、不创建组件，也不取得外部资源所有权。
  // 失败/边界：直接实例化时四个钩子均为空操作；需要平台行为的插件必须覆盖对应阶段。
  function new(string name = "rdma_env_plugin");
    super.new(name);
  endfunction

  // 功能：提供 dpu 系统 build 前的可覆盖钩子，例如安装 factory override 或调整平台配置。
  // 输入/输出及副作用：env 为待构建环境的非拥有引用；基类实现有意不读取或修改它。
  // 失败/边界：插件不需要预构建动作时保持空操作；派生实现必须在该阶段内完成影响类型创建的配置。
  virtual function void pre_build(rdma_env env);
  endfunction

  // 功能：提供 env build_phase 末尾的可覆盖钩子，供插件创建并连接依赖已装配 dpu 系统的组件。
  // 输入/输出及副作用：env 为当前环境非拥有引用；基类不创建对象或改变拓扑。
  // 失败/边界：无需额外组件的插件可沿用空操作；派生类不得在此假设 Function 已 probe。
  virtual function void build(rdma_env env);
  endfunction

  // 功能：提供 Function probe 后、业务流量前的可覆盖运行期准备钩子。
  // 输入/输出及副作用：env 已完成静态装配；基类立即完成且不持有 objection、不启动线程或外部进程。
  // 失败/边界：无需运行期准备时为空操作；派生 task 失败必须自行报告，接口没有 status 返回值。
  virtual task start(rdma_env env);
  endtask

  // 功能：提供 env report_phase 的可覆盖收尾钩子，供插件检查计数或释放其拥有的外部资源。
  // 输入/输出及副作用：env 为已运行环境；基类不报告、不释放，也不修改仿真结果。
  // 失败/边界：未分配资源的插件可沿用空操作；派生实现必须自行处理部分启动后的幂等收尾。
  virtual function void report(rdma_env env);
  endfunction
endclass

class rdma_env_cfg extends uvm_object;
  `uvm_object_utils(rdma_env_cfg)

  // 运行模式（PEER / RXE / DUT）；rxe 插件在 pre_build 中切换为 RXE。
  rdma_env_mode_e mode;
  // 拓扑与平台。
  rdma_env_func_t funcs[$];
  // 插件提供的远端 Function 数（如 rxe），下标排在 dpu Function 之后。
  int unsigned remote_funcs;
  string link_type;
  rdma_env_plugin plugins[$];
  // 声明式 RDMA 流量输入与 resolver 生成的冻结快照。flow_plan 与 resolved_config 由测试拥有；
  // env 只在缺少 resolved_config 时读取 plan 并保存发布结果，之后各组件消费只读快照。
  rdma_flow_plan flow_plan;
  rdma_resolved_config resolved_config;
  // DUT link 外部 endpoint 与 frozen route snapshot；仅 rdma_dut_link 使用，普通 loopback 忽略。
  rdma_dut_frame_endpoint dut_endpoint;
  rdma_dut_link_snapshot dut_link_snapshot;
  int unsigned dut_port;
  bit [47:0] dut_mac;
  // QP 默认属性（IB timeout 0 为不超时）。
  int unsigned mtu;
  int unsigned timeout;
  int unsigned retry;
  int unsigned rnr_retry;
  int unsigned min_rnr;
  int unsigned qp_depth;
  bit [31:0] ud_qkey;
  // 时间：monitor 轮询间隔、等待一个完成的上限。
  time poll_interval;
  time response_timeout;
  // 检查开关与协议偏差（按规则名降级为 info）。
  bit checker_enable;
  bit cov_enable;
  string deviations[$];
  // 业务模板（每种业务一个）与分布表达式求值器（适配层可替换为 aip_core 实现）。
  rdma_biz_cfg biz[$];
  rdma_value_spec spec;
  protected bit finalized;

  // 功能：构造默认配置：PEER 模式，链路 rdma_link（loopback），PMTU 1024，timeout 14，重试 7，
  //   min_rnr 1，深度 256；为六种内置业务各建一个默认模板，表达式求值器为最小语法实现。
  // 输入/输出及副作用：name 为 UVM 名；创建业务模板与求值器对象并由本配置持有。
  // 失败/边界：拓扑须由测试填写；业务模板只在业务序列中使用，其他序列不读取。
  function new(string name = "rdma_env_cfg");
    rdma_biz_kind_e k;

    super.new(name);
    mode = RDMA_ENV_MODE_PEER;
    link_type = "rdma_link";
    flow_plan = null;
    resolved_config = null;
    dut_endpoint = null;
    dut_link_snapshot = null;
    dut_port = 0;
    dut_mac = '0;
    mtu = 1024;
    timeout = 14;
    retry = 7;
    rnr_retry = 7;
    min_rnr = 1;
    qp_depth = 256;
    ud_qkey = 32'h8001_0000;
    poll_interval = 10ns;
    response_timeout = 100us;
    checker_enable = 1'b1;
    cov_enable = 1'b1;
    finalized = 1'b0;
    spec = rdma_value_spec::type_id::create("value_spec");
    k = k.first();
    do begin
      biz.push_back(rdma_biz_cfg::type_id::create({"biz_", k.name()}));
      biz[$].set_kind(k);
      k = k.next();
    end while (k != k.first());
  endfunction

  // 功能：把 host/PF/kind/VF 四元组追加为一个待交给 rdma_dpu_system 的 Function 声明。
  // 输入/输出及副作用：构造值类型 rdma_env_func_t 并保持调用顺序追加到 funcs，不立即修改 dpu_common。
  // 失败/边界：本函数不去重或验证拓扑编号；重复 key、VF/PF kind 与 vf 不一致等由系统 build 拒绝。
  function void add_func(int unsigned host, int unsigned pf = 0,
                         dpu_function_kind_e kind = DPU_FUNCTION_PF, int unsigned vf = 0,
                         rdma_func_role_e role = RDMA_FUNC_ROLE_MODEL);
    rdma_env_func_t f;

    f.host = host;
    f.pf = pf;
    f.kind = kind;
    f.vf = vf;
    f.role = role;
    funcs.push_back(f);
  endfunction

  // 功能：按参数名（send/write/read/atomic/ud/urc）查找业务模板。
  // 输入/输出及副作用：纯查询，返回模板句柄（仍归本配置所有）。
  // 失败/边界：名字区分大小写；未知名字返回 null。
  function rdma_biz_cfg find_biz(string name);
    foreach (biz[i])
      if (biz[i].biz_name() == name)
        return biz[i];
    return null;
  endfunction

  // 功能：只启用名单内的业务，其余禁用；空名单表示全部启用。
  // 输入/输出及副作用：names 为业务参数名列表；修改各模板的 enable。
  // 失败/边界：名单含未知业务名时 uvm_error 并忽略该名字。
  function void enable_biz(string names[$]);
    foreach (biz[i])
      biz[i].enable = names.size() == 0;
    foreach (names[i]) begin
      rdma_biz_cfg b;

      b = find_biz(names[i]);
      if (b == null)
        `uvm_error("RDMA_CFG", {"unknown business in rdma.biz.en: ", names[i]})
      else
        b.enable = 1'b1;
    end
  endfunction

  // 功能：校验模式与拓扑，并让每个业务模板解析继承值（取本配置的 QP 默认属性）、校验、冻结。
  // 输入/输出及副作用：修改业务模板的继承字段并置 finalized，返回首个错误状态或成功。
  // 失败/边界：拓扑为空、存在 DUT 角色 Function（V1 未实现 DUT 桥接与 RM）、mode 与链路/远端
  //   Function 不一致、任一业务模板非法均返回错误；重复调用幂等。
  function rdma_status finalize();
    rdma_status status;

    if (finalized)
      return rdma_status::success();
    if (funcs.size() == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "rdma_env_cfg has no Function");
    foreach (funcs[i])
      if (funcs[i].role == RDMA_FUNC_ROLE_DUT)
        return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                 $sformatf("f%0d role DUT: DUT bridge/RM not implemented yet", i));
    if (mode == RDMA_ENV_MODE_DUT && link_type != "rdma_dut_link")
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "mode DUT requires link_type rdma_dut_link");
    if (mode == RDMA_ENV_MODE_RXE && remote_funcs == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "mode RXE requires a remote Function");
    foreach (biz[i]) begin
      status = biz[i].finalize(qp_depth, mtu, ud_qkey, timeout, retry, rnr_retry, min_rnr);
      if (!status.ok())
        return status;
    end
    finalized = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：生成最终生效配置的多行摘要（模式、拓扑、链路、环境默认、时间、检查开关、全部业务模板）。
  // 输入/输出及副作用：纯格式化，不修改配置。
  // 失败/边界：finalize 之前调用时业务继承字段显示为 0/-1。
  function string describe();
    string s;

    s = $sformatf("RDMA effective configuration\n  mode=%s link=%s funcs=%0d remote_funcs=%0d\n",
                  mode.name(), link_type, funcs.size(), remote_funcs);
    foreach (funcs[i])
      s = {s, $sformatf("  f%0d host=%0d pf=%0d kind=%s vf=%0d role=%s\n", i, funcs[i].host,
                        funcs[i].pf, funcs[i].kind.name(), funcs[i].vf, funcs[i].role.name())};
    s = {s, $sformatf({"  rdma.env: qp_depth=%0d mtu=%0d timeout=%0d retry=%0d rnr_retry=%0d ",
                       "min_rnr=%0d ud_qkey=0x%08h poll=%0t response_timeout=%0t checker=%0b ",
                       "cov=%0b\n"},
                      qp_depth, mtu, timeout, retry, rnr_retry, min_rnr, ud_qkey, poll_interval,
                      response_timeout, checker_enable, cov_enable)};
    foreach (deviations[i])
      s = {s, "  deviation: ", deviations[i], "\n"};
    foreach (biz[i])
      s = {s, biz[i].describe(), "\n"};
    return s;
  endfunction

  // 功能：按完整字符串判断协议规则 name 是否已列入偏差清单。
  // 输入/输出及副作用：顺序读取 deviations，首次精确匹配返回 1；不修改队列或规则状态。
  // 失败/边界：匹配区分大小写且不做前后空白归一化；空清单或未知名字返回 0，重复项不改变结果。
  function bit deviates(string name);
    foreach (deviations[i])
      if (deviations[i] == name)
        return 1'b1;
    return 1'b0;
  endfunction
endclass
