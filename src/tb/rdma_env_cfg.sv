// 目录：验证组件层 tb/rdma_env_cfg.sv。
// 层：验证组件。
// 职责：env 配置：拓扑（dpu_common 的 Host/PF/VF）、主机内存工厂、链路类型、插件、QP 默认属性、时间参数与
//   检查开关。测试经 uvm_config_db 把它交给 env（键 "cfg"）。
// 依赖：rdma_dpu_adapter_pkg（Function 声明与内存工厂）。
// 所有权：配置对象只持有工厂/插件引用。
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
  // 功能：构造。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_env_plugin");
    super.new(name);
  endfunction

  // 功能：dpu 系统 build 之前（如安装 factory 覆盖）。
  // 输入/输出及副作用：由实现决定。
  // 失败/边界：无。
  virtual function void pre_build(rdma_env env);
  endfunction

  // 功能：env build_phase 末尾（创建组件）。
  // 输入/输出及副作用：由实现决定。
  // 失败/边界：无。
  virtual function void build(rdma_env env);
  endfunction

  // 功能：Function probe 之后、流量开始之前（运行期准备）。
  // 输入/输出及副作用：由实现决定。
  // 失败/边界：无。
  virtual task start(rdma_env env);
  endtask

  // 功能：env report_phase（插件自身的结束检查）。
  // 输入/输出及副作用：由实现决定。
  // 失败/边界：无。
  virtual function void report(rdma_env env);
  endfunction
endclass

class rdma_env_cfg extends uvm_object;
  `uvm_object_utils(rdma_env_cfg)

  // 拓扑与平台。
  rdma_env_func_t funcs[$];
  // 插件提供的远端 Function 数（如 rxe），下标排在 dpu Function 之后。
  int unsigned remote_funcs;
  rdma_dpu_mem_factory mem_factory;
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
  bit sb_enable;
  bit checker_enable;
  bit cov_enable;
  string deviations[$];

  // 功能：构造默认配置：链路 rdma_link（loopback），PMTU 1024，timeout 14，重试 7，min_rnr 1，深度 256。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：拓扑与内存工厂须由测试填写。
  function new(string name = "rdma_env_cfg");
    super.new(name);
    mem_factory = null;
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
    sb_enable = 1'b1;
    checker_enable = 1'b1;
    cov_enable = 1'b1;
  endfunction

  // 功能：声明一个 Function。
  // 输入/输出及副作用：追加 funcs。
  // 失败/边界：无。
  function void add_func(int unsigned host, int unsigned pf = 0,
                         dpu_function_kind_e kind = DPU_FUNCTION_PF, int unsigned vf = 0);
    rdma_env_func_t f;

    f.host = host;
    f.pf = pf;
    f.kind = kind;
    f.vf = vf;
    funcs.push_back(f);
  endfunction

  // 功能：规则 name 是否在偏差清单中。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function bit deviates(string name);
    foreach (deviations[i])
      if (deviations[i] == name)
        return 1'b1;
    return 1'b0;
  endfunction
endclass
