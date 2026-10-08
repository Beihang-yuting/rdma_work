// 目录：验证组件层 tb/rdma_env_cfg.sv。
// 层：验证组件。
// 职责：env 配置：拓扑（dpu_common 的 Host/PF/VF）、链路类型、插件、QP 默认属性、时间参数与
//   检查开关。测试经 uvm_config_db 把它交给 env（键 "cfg"）。
// 依赖：rdma_dpu_adapter_pkg（Function 声明）。
// 所有权：配置对象只持有插件引用。
// 生命周期：测试 build_phase 创建，env build_phase 读取。

typedef class rdma_env;

// 一个 Function 的声明（交给 rdma_dpu_system）。
typedef struct {
  int unsigned host;
  int unsigned pf;
  dpu_function_kind_e kind;
  int unsigned vf;
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

  // 拓扑与平台。
  rdma_env_func_t funcs[$];
  // 插件提供的远端 Function 数（如 rxe），下标排在 dpu Function 之后。
  int unsigned remote_funcs;
  string link_type;
  rdma_env_plugin plugins[$];
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

  // 功能：构造默认配置：链路 rdma_link（loopback），PMTU 1024，timeout 14，重试 7，min_rnr 1，深度 256。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：拓扑须由测试填写。
  function new(string name = "rdma_env_cfg");
    super.new(name);
    link_type = "rdma_link";
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
  endfunction

  // 功能：把 host/PF/kind/VF 四元组追加为一个待交给 rdma_dpu_system 的 Function 声明。
  // 输入/输出及副作用：构造值类型 rdma_env_func_t 并保持调用顺序追加到 funcs，不立即修改 dpu_common。
  // 失败/边界：本函数不去重或验证拓扑编号；重复 key、VF/PF kind 与 vf 不一致等由系统 build 拒绝。
  function void add_func(int unsigned host, int unsigned pf = 0,
                         dpu_function_kind_e kind = DPU_FUNCTION_PF, int unsigned vf = 0);
    rdma_env_func_t f;

    f.host = host;
    f.pf = pf;
    f.kind = kind;
    f.vf = vf;
    funcs.push_back(f);
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
