// 目录：测试层 rdma_env_test_pkg.sv。
// 层：测试。
// 职责：env 测试：基类按配置（两 Function：Host0 PF0、Host1 PF0）建立 rdma_env 并运行一个虚拟序列；
//   子类只选链路与序列（主机内存恒为外部 host_mem）。+RDMA_LINK=<链路类名>、+RDMA_VSEQ=<序列类名>
//   可覆盖默认值；随后经 aip_core 加载 +rdma.env.* / +rdma.{qp,mem,pkt,traffic}.* 参数（命令行优先于测试 configure）。
//   rdma_env_traffic_test 按统一场景生成流量。
//   rxe suite 另有 rdma_env_rxe_test。
// 依赖：rdma_drv_pkg、rdma_env_pkg、rdma_aip_cfg_pkg 和 rdma_unit_test_pkg。
// 所有权：测试拥有配置与 env。
// 生命周期：build 建 env，run_phase 运行序列。
package rdma_env_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import rdma_types_pkg::*;
  import rdma_codec_pkg::*;
  import rdma_drv_pkg::*;
  import rdma_host_mem_pkg::*;
  import dpu_resource_pkg::*;
  import rdma_dpu_adapter_pkg::*;
  import rdma_env_pkg::*;
  import rdma_aip_cfg_pkg::*;
  import rdma_unit_test_pkg::*;
`ifdef RDMA_RXE_TEST
  import rdma_rxe_env_pkg::*;
`endif

  class rdma_env_base_test extends uvm_test;
    `uvm_component_utils(rdma_env_base_test)

    rdma_env_cfg	cfg;
    rdma_env	env;
    string	link_type;
    string	vseq_type;

    // 功能：构造 env 测试基类，并选择 loopback 链路与 basic_traffic 作为未覆盖时的默认场景。
    // 输入/输出及副作用：name/parent 建立 UVM 层级；初始化 link_type/vseq_type，不创建 cfg 或 env。
    // 失败/边界：构造阶段不解析 plusarg；派生类可在 super.new 返回后替换两个默认类型名。
    extern function new(string	name = "rdma_env_base_test", uvm_component	parent = null);

    // 功能：解析链路/序列 plusarg，建立两 Host 各一 PF 的默认配置，经 configure 后再由 aip_core 加载
    //   +rdma.env.* 与 +rdma.{qp,mem,pkt,traffic}.* 参数（以当前配置为默认值），最后创建测试 env。
    // 输入/输出及副作用：phase 传给基类；创建并持有 cfg/env，向 env 实例写入 config_db；vseq_type 可被
    //   +rdma.env.vseq 覆盖。
    // 失败/边界：未知链路由 env factory 创建阶段报告；未知序列延迟到 run_traffic 报 UVM_FATAL；参数
    //   语法错误由 aip_core FATAL，取值约束在 env finalize 时校验。
    extern function void build_phase(uvm_phase	phase);

    // 功能：提供派生测试的配置钩子；基类实现保留 build_phase 建立的双 Host 默认拓扑。
    // 输入/输出及副作用：c 为待交给 env 的可变配置；基类不修改它。
    // 失败/边界：调用时 c 必须非空且尚未发布到 config_db；派生实现不得在 env 创建后依赖此钩子。
    extern virtual function void configure(rdma_env_cfg	c);

    // 功能：运行流量；scoreboard 须有检查。
    // 输入/输出及副作用：持有 objection 至流量结束。
    // 失败/边界：未检查任何东西报 UVM_ERROR。
    task run_phase(uvm_phase	phase);
      phase.raise_objection(this);
      `uvm_info("ENV_TEST", {"link=", cfg.link_type, " vseq=", vseq_type},
                UVM_LOW)
      run_traffic();
      if (env.sb.checked == 0)
        `uvm_error("ENV_TEST", "scoreboard checked nothing")
      phase.drop_objection(this);
    endtask

    // 功能：按名字创建并运行虚拟序列（子类可改为多段流量）。
    // 输入/输出及副作用：启动序列。
    // 失败/边界：序列名无效 UVM_FATAL。
    virtual task run_traffic();
      uvm_sequence_base	vseq;

      if (!$cast(vseq, uvm_factory::get().create_object_by_name(vseq_type, "", "vseq")))
        `uvm_fatal("ENV_TEST", {"unknown RDMA_VSEQ: ", vseq_type})
      vseq.start(env.vseqr);
    endtask
  endclass

    // 功能：构造 env 测试基类，并选择 loopback 链路与 basic_traffic 作为未覆盖时的默认场景。
    // 输入/输出及副作用：name/parent 建立 UVM 层级；初始化 link_type/vseq_type，不创建 cfg 或 env。
    // 失败/边界：构造阶段不解析 plusarg；派生类可在 super.new 返回后替换两个默认类型名。
function rdma_env_base_test::new(string	name = "rdma_env_base_test", uvm_component	parent = null);
      super.new(name, parent);
      link_type = "rdma_link";
      vseq_type = "rdma_basic_traffic_vseq";
endfunction

    // 功能：解析链路/序列 plusarg，建立两 Host 各一 PF 的默认配置，经 configure 后再由 aip_core 加载
    //   +rdma.env.* 与 +rdma.{qp,mem,pkt,traffic}.* 参数（以当前配置为默认值），最后创建测试 env。
    // 输入/输出及副作用：phase 传给基类；创建并持有 cfg/env，向 env 实例写入 config_db；vseq_type 可被
    //   +rdma.env.vseq 覆盖。
    // 失败/边界：未知链路由 env factory 创建阶段报告；未知序列延迟到 run_traffic 报 UVM_FATAL；参数
    //   语法错误由 aip_core FATAL，取值约束在 env finalize 时校验。
function void rdma_env_base_test::build_phase(uvm_phase	phase);
      rdma_status	status;

      super.build_phase(phase);
      void'($value$plusargs("RDMA_LINK=%s", link_type));
      void'($value$plusargs("RDMA_VSEQ=%s", vseq_type));
      cfg = rdma_env_cfg::type_id::create("cfg");
      cfg.add_func(0);
      cfg.add_func(1);
      cfg.link_type = link_type;
      configure(cfg);
      status = rdma_aip_cfg_loader::load(cfg, vseq_type);
      if (!status.ok())
        `uvm_fatal("RDMA_CFG", status.convert2string())
      uvm_config_db#(rdma_env_cfg)::set(this, "env", "cfg", cfg);
      env = rdma_env::type_id::create("env", this);
endfunction

    // 功能：提供派生测试的配置钩子；基类实现保留 build_phase 建立的双 Host 默认拓扑。
    // 输入/输出及副作用：c 为待交给 env 的可变配置；基类不修改它。
    // 失败/边界：调用时 c 必须非空且尚未发布到 config_db；派生实现不得在 env 创建后依赖此钩子。
function void rdma_env_base_test::configure(rdma_env_cfg	c);
endfunction

  // loopback 链路的全功能流量。
  class rdma_env_basic_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_basic_test)

    // 功能：构造使用默认 loopback/basic_traffic 组合的基础环境测试。
    // 输入/输出及副作用：name/parent 建立 UVM 层级；全部场景选择继承 rdma_env_base_test 默认值。
    // 失败/边界：不增加配置钩子或资源；factory/build 失败沿用基类报告。
    extern function new(string	name = "rdma_env_basic_test", uvm_component	parent = null);
  endclass

    // 功能：构造使用默认 loopback/basic_traffic 组合的基础环境测试。
    // 输入/输出及副作用：name/parent 建立 UVM 层级；全部场景选择继承 rdma_env_base_test 默认值。
    // 失败/边界：不增加配置钩子或资源；factory/build 失败沿用基类报告。
function rdma_env_basic_test::new(string	name = "rdma_env_basic_test", uvm_component	parent = null);
      super.new(name, parent);
endfunction

  // net_packet 帧编解码链路的全功能流量。
  class rdma_env_netpkt_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_netpkt_test)

    // 功能：构造经 net_packet 编解码链路运行 basic_traffic 的环境测试。
    // 输入/输出及副作用：name/parent 建立 UVM 层级；把 link_type 覆盖为 rdma_link_netpkt。
    // 失败/边界：不改变默认双 Host 拓扑；net_packet factory/依赖缺失由 env build 报告。
    extern function new(string	name = "rdma_env_netpkt_test", uvm_component	parent = null);
  endclass

    // 功能：构造经 net_packet 编解码链路运行 basic_traffic 的环境测试。
    // 输入/输出及副作用：name/parent 建立 UVM 层级；把 link_type 覆盖为 rdma_link_netpkt。
    // 失败/边界：不改变默认双 Host 拓扑；net_packet factory/依赖缺失由 env build 报告。
function rdma_env_netpkt_test::new(string	name = "rdma_env_netpkt_test", uvm_component	parent = null);
      super.new(name, parent);
      link_type = "rdma_link_netpkt";
endfunction

  // net_packet 链路的大流量。
  class rdma_env_high_traffic_test extends rdma_env_netpkt_test;
    `uvm_component_utils(rdma_env_high_traffic_test)

    // 功能：构造在 net_packet 链路上运行 high_traffic 虚拟序列的压力测试。
    // 输入/输出及副作用：name/parent 建立层级；继承 netpkt 链路并覆盖 vseq_type。
    // 失败/边界：流量规模和 drain 超时由 rdma_high_traffic_vseq/env 契约限制，本构造函数不分配流量对象。
    extern function new(string	name = "rdma_env_high_traffic_test", uvm_component	parent = null);
  endclass

    // 功能：构造在 net_packet 链路上运行 high_traffic 虚拟序列的压力测试。
    // 输入/输出及副作用：name/parent 建立层级；继承 netpkt 链路并覆盖 vseq_type。
    // 失败/边界：流量规模和 drain 超时由 rdma_high_traffic_vseq/env 契约限制，本构造函数不分配流量对象。
function rdma_env_high_traffic_test::new(string	name = "rdma_env_high_traffic_test", uvm_component	parent = null);
      super.new(name, parent);
      vseq_type = "rdma_high_traffic_vseq";
endfunction
  // 错误场景（loopback）。
  class rdma_env_errors_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_errors_test)

    // 功能：构造在默认 loopback 链路上运行 errors 虚拟序列的错误场景测试。
    // 输入/输出及副作用：name/parent 建立层级；仅把 vseq_type 覆盖为 rdma_errors_vseq。
    // 失败/边界：预期错误的降级与断言由序列/scoreboard 负责，本构造函数不放宽 UVM 报告。
    extern function new(string	name = "rdma_env_errors_test", uvm_component	parent = null);
  endclass

    // 功能：构造在默认 loopback 链路上运行 errors 虚拟序列的错误场景测试。
    // 输入/输出及副作用：name/parent 建立层级；仅把 vseq_type 覆盖为 rdma_errors_vseq。
    // 失败/边界：预期错误的降级与断言由序列/scoreboard 负责，本构造函数不放宽 UVM 报告。
function rdma_env_errors_test::new(string	name = "rdma_env_errors_test", uvm_component	parent = null);
      super.new(name, parent);
      vseq_type = "rdma_errors_vseq";
endfunction

  // 可靠传输（netpkt 链路以覆盖 ICRC 丢弃；响应超时编码 8 ≈ 1ms 使超时重传场景可运行）。
  class rdma_env_reliability_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_reliability_test)

    // 功能：构造使用 net_packet 链路和 reliability 序列的重传/超时环境测试。
    // 输入/输出及副作用：name/parent 建立层级；覆盖 link_type 与 vseq_type，尚不修改 cfg 时间参数。
    // 失败/边界：实际响应预算在 configure 设置；构造阶段不启动计时器或持有网络资源。
    extern function new(string	name = "rdma_env_reliability_test", uvm_component	parent = null);

    // 功能：把可靠性场景的设备响应超时编码设为 8，并把测试等待预算放宽到 1ms。
    // 输入/输出及副作用：修改非空 c.scenario.qp.timeout/c.response_timeout，保留其拓扑、重试次数和插件。
    // 失败/边界：仅适用于 env 创建前的配置钩子；空 c 或运行期重配不在本函数契约内。
    extern virtual function void configure(rdma_env_cfg	c);
  endclass

    // 功能：构造使用 net_packet 链路和 reliability 序列的重传/超时环境测试。
    // 输入/输出及副作用：name/parent 建立层级；覆盖 link_type 与 vseq_type，尚不修改 cfg 时间参数。
    // 失败/边界：实际响应预算在 configure 设置；构造阶段不启动计时器或持有网络资源。
function rdma_env_reliability_test::new(string	name = "rdma_env_reliability_test", uvm_component	parent = null);
      super.new(name, parent);
      link_type = "rdma_link_netpkt";
      vseq_type = "rdma_reliability_vseq";
endfunction

    // 功能：把可靠性场景的设备响应超时编码设为 8，并把测试等待预算放宽到 1ms。
    // 输入/输出及副作用：修改非空 c.scenario.qp.timeout/c.response_timeout，保留其拓扑、重试次数和插件。
    // 失败/边界：仅适用于 env 创建前的配置钩子；空 c 或运行期重配不在本函数契约内。
function void rdma_env_reliability_test::configure(rdma_env_cfg	c);
      c.scenario.qp.timeout = 8;
      c.response_timeout = 1ms;
endfunction

  // SRQ 共享（双向）。
  class rdma_env_srq_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_srq_test)

    // 功能：构造运行双向共享接收队列场景的环境测试。
    // 输入/输出及副作用：name/parent 建立层级；把 vseq_type 设为 rdma_srq_vseq，保留 loopback 链路。
    // 失败/边界：SRQ 容量和资源回收由序列检查；构造阶段不创建 SRQ。
    extern function new(string	name = "rdma_env_srq_test", uvm_component	parent = null);
  endclass

    // 功能：构造运行双向共享接收队列场景的环境测试。
    // 输入/输出及副作用：name/parent 建立层级；把 vseq_type 设为 rdma_srq_vseq，保留 loopback 链路。
    // 失败/边界：SRQ 容量和资源回收由序列检查；构造阶段不创建 SRQ。
function rdma_env_srq_test::new(string	name = "rdma_env_srq_test", uvm_component	parent = null);
      super.new(name, parent);
      vseq_type = "rdma_srq_vseq";
endfunction

  // QP 生命周期（SQD、销毁重建）。
  class rdma_env_lifecycle_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_lifecycle_test)

    // 功能：构造覆盖 SQD、QP 销毁与重建状态迁移的生命周期环境测试。
    // 输入/输出及副作用：name/parent 建立层级；把 vseq_type 设为 rdma_qp_lifecycle_vseq。
    // 失败/边界：状态迁移拒绝与资源泄漏由序列/scoreboard 判定；构造阶段不创建 QP。
    extern function new(string	name = "rdma_env_lifecycle_test", uvm_component	parent = null);
  endclass

    // 功能：构造覆盖 SQD、QP 销毁与重建状态迁移的生命周期环境测试。
    // 输入/输出及副作用：name/parent 建立层级；把 vseq_type 设为 rdma_qp_lifecycle_vseq。
    // 失败/边界：状态迁移拒绝与资源泄漏由序列/scoreboard 判定；构造阶段不创建 QP。
function rdma_env_lifecycle_test::new(string	name = "rdma_env_lifecycle_test", uvm_component	parent = null);
      super.new(name, parent);
      vseq_type = "rdma_qp_lifecycle_vseq";
endfunction

  // 多 Function 与复位范围：Host0 PF0、Host0 VF1、Host1 PF0、Host1 VF1。
  class rdma_env_multifunc_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_multifunc_test)

    // 功能：构造覆盖跨 Host PF/VF authority 与复位隔离的多 Function 环境测试。
    // 输入/输出及副作用：name/parent 建立层级；选择 rdma_multifunc_vseq，拓扑稍后由 configure 重建。
    // 失败/边界：构造后 cfg 尚不存在；调用方不能在 build_phase 前读取四 Function 拓扑。
    extern function new(string	name = "rdma_env_multifunc_test", uvm_component	parent = null);

    // 功能：把默认拓扑替换为 Host0/Host1 各一个 PF0 与 VF1，供多 Function 序列验证隔离。
    // 输入/输出及副作用：清空 c.funcs 后按稳定顺序加入四个 Function；其他配置字段保持不变。
    // 失败/边界：c 必须非空且尚未冻结；重复调用先清空列表，因此拓扑结果幂等。
    extern virtual function void configure(rdma_env_cfg	c);
  endclass

    // 功能：构造覆盖跨 Host PF/VF authority 与复位隔离的多 Function 环境测试。
    // 输入/输出及副作用：name/parent 建立层级；选择 rdma_multifunc_vseq，拓扑稍后由 configure 重建。
    // 失败/边界：构造后 cfg 尚不存在；调用方不能在 build_phase 前读取四 Function 拓扑。
function rdma_env_multifunc_test::new(string	name = "rdma_env_multifunc_test", uvm_component	parent = null);
      super.new(name, parent);
      vseq_type = "rdma_multifunc_vseq";
endfunction

    // 功能：把默认拓扑替换为 Host0/Host1 各一个 PF0 与 VF1，供多 Function 序列验证隔离。
    // 输入/输出及副作用：清空 c.funcs 后按稳定顺序加入四个 Function；其他配置字段保持不变。
    // 失败/边界：c 必须非空且尚未冻结；重复调用先清空列表，因此拓扑结果幂等。
function void rdma_env_multifunc_test::configure(rdma_env_cfg	c);
      c.funcs.delete();
      c.add_func(0);
      c.add_func(0, 0, DPU_FUNCTION_VF, 1);
      c.add_func(1);
      c.add_func(1, 0, DPU_FUNCTION_VF, 1);
endfunction

  // 随机流量（netpkt 链路）。
  class rdma_env_random_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_random_test)

    // 功能：构造在 net_packet 链路上运行随机事务组合的环境测试。
    // 输入/输出及副作用：name/parent 建立层级；覆盖 link_type 与 vseq_type，不预生成随机 item。
    // 失败/边界：随机约束失败由 rdma_random_vseq 报告；种子由仿真器/runner 管理。
    extern function new(string	name = "rdma_env_random_test", uvm_component	parent = null);
  endclass

    // 功能：构造在 net_packet 链路上运行随机事务组合的环境测试。
    // 输入/输出及副作用：name/parent 建立层级；覆盖 link_type 与 vseq_type，不预生成随机 item。
    // 失败/边界：随机约束失败由 rdma_random_vseq 报告；种子由仿真器/runner 管理。
function rdma_env_random_test::new(string	name = "rdma_env_random_test", uvm_component	parent = null);
      super.new(name, parent);
      link_type = "rdma_link_netpkt";
      vseq_type = "rdma_random_vseq";
endfunction

  // 按统一场景生成流量（netpkt 链路，使报文属性体现在帧上）；业务与参数由 +rdma.{qp,mem,pkt,traffic}.* 选择。
  class rdma_env_traffic_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_traffic_test)

    // 功能：构造在 net_packet 链路上运行 rdma_traffic_vseq 的环境测试；默认 RC SEND，所有操作共享一组资源。
    // 输入/输出及副作用：name/parent 建立层级；覆盖 link_type 与 vseq_type，不创建资源。
    // 失败/边界：业务参数非法时 env finalize 报 UVM_FATAL；种子由仿真器/runner 管理。
    extern function new(string	name = "rdma_env_traffic_test", uvm_component	parent = null);
  endclass

    // 功能：构造在 net_packet 链路上运行 rdma_traffic_vseq 的环境测试；默认 RC SEND，所有操作共享一组资源。
    // 输入/输出及副作用：name/parent 建立层级；覆盖 link_type 与 vseq_type，不创建资源。
    // 失败/边界：业务参数非法时 env finalize 报 UVM_FATAL；种子由仿真器/runner 管理。
function rdma_env_traffic_test::new(string	name = "rdma_env_traffic_test", uvm_component	parent = null);
      super.new(name, parent);
      link_type = "rdma_link_netpkt";
      vseq_type = "rdma_traffic_vseq";
endfunction

`ifdef RDMA_RXE_TEST
  // 与 Linux Soft-RoCE 互打：仿真 Function 0（Host0 PF0）↔ 远端 Function 1（rxe）；依次运行
  //   basic_traffic、errors、srq、reliability（URC、远端多 SGE、远端受限 MR、超时类场景由序列跳过）。
  class rdma_env_rxe_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_rxe_test)

    // 功能：构造一个仿真 Function 与一个 Soft-RoCE 远端 Function 互通的环境测试。
    // 输入/输出及副作用：name/parent 建立层级；沿用基类默认类型，拓扑和插件在 configure 设置。
    // 失败/边界：构造阶段不检查 TAP/rxe 设备；缺少外部环境由 rxe 插件启动阶段报告。
    extern function new(string	name = "rdma_env_rxe_test", uvm_component	parent = null);

    // 功能：把默认拓扑缩为 Host0 PF0，并加入负责一个远端 Function 的 rxe 插件。
    // 输入/输出及副作用：清空并重建 c.funcs，向 c.plugins 追加新插件；其余链路参数保持不变。
    // 失败/边界：c 必须非空且尚未发布；重复调用会追加重复插件，因此只允许基类 build 调用一次。
    extern virtual function void configure(rdma_env_cfg	c);

    // 功能：在同一 rxe 环境依次运行 basic、errors、srq、reliability 四种虚拟序列。
    // 输入/输出及副作用：逐项更新 vseq_type，并复用基类 run_traffic 在 env.vseqr 上启动序列。
    // 失败/边界：任一类型未注册会由基类报 UVM_FATAL；严格串行，后一场景可观察前一场景保留的环境状态。
    virtual task run_traffic();
      string	names[] = '{"rdma_basic_traffic_vseq", "rdma_errors_vseq", "rdma_srq_vseq",
                         "rdma_reliability_vseq"};

      foreach (names[i]) begin
        vseq_type = names[i];
        super.run_traffic();
      end
    endtask
  endclass

    // 功能：构造一个仿真 Function 与一个 Soft-RoCE 远端 Function 互通的环境测试。
    // 输入/输出及副作用：name/parent 建立层级；沿用基类默认类型，拓扑和插件在 configure 设置。
    // 失败/边界：构造阶段不检查 TAP/rxe 设备；缺少外部环境由 rxe 插件启动阶段报告。
function rdma_env_rxe_test::new(string	name = "rdma_env_rxe_test", uvm_component	parent = null);
      super.new(name, parent);
endfunction

    // 功能：把默认拓扑缩为 Host0 PF0，并加入负责一个远端 Function 的 rxe 插件。
    // 输入/输出及副作用：清空并重建 c.funcs，向 c.plugins 追加新插件；其余链路参数保持不变。
    // 失败/边界：c 必须非空且尚未发布；重复调用会追加重复插件，因此只允许基类 build 调用一次。
function void rdma_env_rxe_test::configure(rdma_env_cfg	c);
      c.funcs.delete();
      c.add_func(0);
      c.plugins.push_back(rdma_rxe_plugin::type_id::create("rxe_plugin"));
endfunction
`endif
  `include "rdma_scenario_tests.sv"
endpackage
