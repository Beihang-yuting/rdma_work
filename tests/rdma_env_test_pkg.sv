// 目录：测试层 rdma_env_test_pkg.sv。
// 层：测试。
// 职责：env 测试：基类按配置（两 Function：Host0 PF0、Host1 PF0）建立 rdma_env 并运行一个虚拟序列；
//   子类只选链路、内存与序列。+RDMA_LINK=<链路类名>、+RDMA_MEM=mock|host_mem、+RDMA_VSEQ=<序列类名>
//   可覆盖默认值。
//   pcie_work suite 另有 PCIe 插件与 rdma_env_pcie_test；rxe suite 另有 rdma_env_rxe_test。
// 依赖：rdma_env_pkg、rdma_unit_test_pkg（mock 与真实 host_mem 内存工厂）、pcie_work（可选）。
// 所有权：测试拥有配置与 env。
// 生命周期：build 建 env，run_phase 运行序列。
package rdma_env_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import rdma_types_pkg::*;
  import rdma_codec_pkg::*;
  import dpu_resource_pkg::*;
  import rdma_dpu_adapter_pkg::*;
  import rdma_env_pkg::*;
  import rdma_unit_test_pkg::*;
`ifdef RDMA_PCIE_WORK_TEST
  import pcie_tl_pkg::*;
  import rdma_pcie_work_pkg::*;
`endif
`ifdef RDMA_RXE_TEST
  import rdma_rxe_env_pkg::*;
`endif

  class rdma_env_base_test extends uvm_test;
    `uvm_component_utils(rdma_env_base_test)

    rdma_env_cfg cfg;
    rdma_env env;
    string link_type;
    string mem_kind;
    string vseq_type;

    // 功能：构造默认选择：loopback 链路、mock 内存、basic_traffic。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_env_base_test", uvm_component parent = null);
      super.new(name, parent);
      link_type = "rdma_link";
      mem_kind = "mock";
      vseq_type = "rdma_basic_traffic_vseq";
    endfunction

    // 功能：应用 plusarg 覆盖，建配置（两 Host 各一 PF）并交给 env。
    // 输入/输出及副作用：设置 config_db，创建 env。
    // 失败/边界：无效内存类型 UVM_FATAL。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      void'($value$plusargs("RDMA_LINK=%s", link_type));
      void'($value$plusargs("RDMA_MEM=%s", mem_kind));
      void'($value$plusargs("RDMA_VSEQ=%s", vseq_type));
      cfg = rdma_env_cfg::type_id::create("cfg");
      cfg.add_func(0);
      cfg.add_func(1);
      cfg.link_type = link_type;
`ifdef RDMA_HOST_MEM_TEST
      if (mem_kind == "host_mem")
        cfg.mem_factory = rdma_host_mem_factory::type_id::create("mem_factory");
      else
`endif
      if (mem_kind == "mock")
        cfg.mem_factory = rdma_mock_mem_factory::type_id::create("mem_factory");
      else
        `uvm_fatal("ENV_TEST", {"unknown RDMA_MEM: ", mem_kind})
      configure(cfg);
      uvm_config_db#(rdma_env_cfg)::set(this, "env", "cfg", cfg);
      env = rdma_env::type_id::create("env", this);
    endfunction

    // 功能：子类钩子：调整配置（拓扑、插件）。
    // 输入/输出及副作用：修改 c。
    // 失败/边界：无。
    virtual function void configure(rdma_env_cfg c);
    endfunction

    // 功能：运行流量；scoreboard 须有检查。
    // 输入/输出及副作用：持有 objection 至流量结束。
    // 失败/边界：未检查任何东西报 UVM_ERROR。
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      `uvm_info("ENV_TEST", {"link=", cfg.link_type, " mem=", mem_kind, " vseq=", vseq_type},
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
      uvm_sequence_base vseq;

      if (!$cast(vseq, uvm_factory::get().create_object_by_name(vseq_type, "", "vseq")))
        `uvm_fatal("ENV_TEST", {"unknown RDMA_VSEQ: ", vseq_type})
      vseq.start(env.vseqr);
    endtask
  endclass

  // loopback 链路 + mock 内存的全功能流量。
  class rdma_env_basic_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_basic_test)

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_env_basic_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction
  endclass

  // net_packet 帧编解码链路 + 真实 host_mem 的全功能流量。
  class rdma_env_netpkt_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_netpkt_test)

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_env_netpkt_test", uvm_component parent = null);
      super.new(name, parent);
      link_type = "rdma_link_netpkt";
      mem_kind = "host_mem";
    endfunction
  endclass

  // net_packet 链路 + 真实 host_mem 的大流量。
  class rdma_env_high_traffic_test extends rdma_env_netpkt_test;
    `uvm_component_utils(rdma_env_high_traffic_test)

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_env_high_traffic_test", uvm_component parent = null);
      super.new(name, parent);
      vseq_type = "rdma_high_traffic_vseq";
    endfunction
  endclass
  // 错误场景（loopback + mock）。
  class rdma_env_errors_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_errors_test)

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_env_errors_test", uvm_component parent = null);
      super.new(name, parent);
      vseq_type = "rdma_errors_vseq";
    endfunction
  endclass

  // 可靠传输（netpkt 链路以覆盖 ICRC 丢弃；响应超时编码 8 ≈ 1ms 使超时重传场景可运行）。
  class rdma_env_reliability_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_reliability_test)

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_env_reliability_test", uvm_component parent = null);
      super.new(name, parent);
      link_type = "rdma_link_netpkt";
      vseq_type = "rdma_reliability_vseq";
    endfunction

    // 功能：响应超时编码 8（约 1ms）；verb 同步等待随之放宽到 4 x 1ms。
    // 输入/输出及副作用：修改 c。
    // 失败/边界：无。
    virtual function void configure(rdma_env_cfg c);
      c.timeout = 8;
      c.response_timeout = 1ms;
    endfunction
  endclass

  // SRQ 共享（双向）。
  class rdma_env_srq_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_srq_test)

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_env_srq_test", uvm_component parent = null);
      super.new(name, parent);
      vseq_type = "rdma_srq_vseq";
    endfunction
  endclass

  // QP 生命周期（SQD、销毁重建）。
  class rdma_env_lifecycle_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_lifecycle_test)

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_env_lifecycle_test", uvm_component parent = null);
      super.new(name, parent);
      vseq_type = "rdma_qp_lifecycle_vseq";
    endfunction
  endclass

  // 多 Function 与复位范围：Host0 PF0、Host0 VF1、Host1 PF0、Host1 VF1。
  class rdma_env_multifunc_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_multifunc_test)

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_env_multifunc_test", uvm_component parent = null);
      super.new(name, parent);
      vseq_type = "rdma_multifunc_vseq";
    endfunction

    // 功能：四个 Function。
    // 输入/输出及副作用：修改 c。
    // 失败/边界：无。
    virtual function void configure(rdma_env_cfg c);
      c.funcs.delete();
      c.add_func(0);
      c.add_func(0, 0, DPU_FUNCTION_VF, 1);
      c.add_func(1);
      c.add_func(1, 0, DPU_FUNCTION_VF, 1);
    endfunction
  endclass

  // 随机流量（netpkt 链路）。
  class rdma_env_random_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_random_test)

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_env_random_test", uvm_component parent = null);
      super.new(name, parent);
      link_type = "rdma_link_netpkt";
      vseq_type = "rdma_random_vseq";
    endfunction
  endclass

`ifdef RDMA_PCIE_WORK_TEST
  // PCIe 承载：install_overrides 让设备 DMA 走 EP MemRd/MemWr、BAR 写走 RC MemWr；每个 Host 一条
  //   RC↔EP 链（rdma_pcie_system），Host 内存为真实 host_mem。结束时检查 TLP 计数一致。
  class rdma_pcie_plugin extends rdma_env_plugin;
    `uvm_object_utils(rdma_pcie_plugin)

    rdma_pcie_system pcie;

    // 功能：构造。
    // 输入/输出及副作用：name 为 UVM 名。
    // 失败/边界：无。
    function new(string name = "rdma_pcie_plugin");
      super.new(name);
    endfunction

    // 功能：dpu 系统 build 前安装 PCIe BAR/DMA 覆盖。
    // 输入/输出及副作用：factory 覆盖。
    // 失败/边界：无。
    virtual function void pre_build(rdma_env env);
      rdma_pcie_system::install_overrides();
    endfunction

    // 功能：按 dpu 快照建立 PCIe 系统，各 Host 的 Root 绑定其 host_mem。
    // 输入/输出及副作用：创建 env 子组件。
    // 失败/边界：内存工厂不是 host_mem 时 UVM_FATAL。
    virtual function void build(rdma_env env);
      rdma_host_mem_factory mems;

      if (!$cast(mems, env.cfg.mem_factory))
        `uvm_fatal("PCIE_PLUGIN", "PCIe needs the host_mem factory")
      pcie = rdma_pcie_system::type_id::create("pcie", env);
      pcie.dpu = env.sys;
      pcie.host_mems = mems.managers;
    endfunction

    // 功能：DMA：EP 发出与 RC 收到的 MemRd/MemWr 数相等、每个 Function 的 BDF 都发过 DMA 且无未知
    //   requester；MMIO：BAR 写次数 = MemWr TLP 数 = 解码数，无拒绝（MAILBOX 检查之外）。
    // 输入/输出及副作用：报 UVM_ERROR。
    // 失败/边界：无。
    virtual function void report(rdma_env env);
      int unsigned seen;
      int unsigned recorded;
      bit counted[bit [15:0]];

      `uvm_info("PCIE_PLUGIN", $sformatf("DMA TLPs: MemRd %0d/%0d, MemWr %0d/%0d (EP/RC)",
                pcie.dma_read_tlps, pcie.host_reads, pcie.dma_write_tlps, pcie.host_writes),
                UVM_LOW)
      if (pcie.dma_read_tlps == 0 || pcie.dma_write_tlps == 0 ||
          pcie.host_reads != pcie.dma_read_tlps || pcie.host_writes != pcie.dma_write_tlps)
        `uvm_error("PCIE_PLUGIN", "device DMA TLPs sent by the EPs and served by the RCs differ")
      seen = 0;
      recorded = 0;
      foreach (env.sys.nodes[i]) begin
        recorded += env.sys.nodes[i].bar.written_offsets.size();
        if (!pcie.host_requesters.exists(env.sys.nodes[i].func.pcie_id.bdf))
          `uvm_error("PCIE_PLUGIN", $sformatf("f%0d BDF %04h issued no DMA", i,
                     env.sys.nodes[i].func.pcie_id.bdf))
        else if (!counted.exists(env.sys.nodes[i].func.pcie_id.bdf)) begin
          counted[env.sys.nodes[i].func.pcie_id.bdf] = 1'b1;
          seen += pcie.host_requesters[env.sys.nodes[i].func.pcie_id.bdf];
        end
      end
      if (seen != pcie.host_reads + pcie.host_writes)
        `uvm_error("PCIE_PLUGIN", "RC served DMA requests from an unknown requester ID")
      if (recorded == 0 || pcie.sent_writes != recorded ||
          pcie.decoded_writes != recorded || pcie.rejected_writes != 1)
        `uvm_error("PCIE_PLUGIN", $sformatf("BAR writes %0d, TLPs %0d, decoded %0d, rejected %0d",
                   recorded, pcie.sent_writes, pcie.decoded_writes, pcie.rejected_writes))
    endfunction

    // 功能：向 Function 0 的 MAILBOX BAR 发 MemWr：须被 EP 拒绝且不路由到设备。
    // 输入/输出及副作用：发一个 TLP。
    // 失败/边界：被接受报 UVM_ERROR。
    task check_mailbox(rdma_env env);
      pcie_tl_rw_seq seq;
      int unsigned routed;

      routed = env.sys.router.routed;
      seq = pcie_tl_rw_seq::type_id::create("mailbox_wr");
      seq.op = PCIE_RW_WRITE;
      seq.addr = env.sys.nodes[0].func.mailbox.base + RDMA_NOTIFY_WINDOW_OFFSET;
      seq.byte_len = 8;
      seq.wdata = new[8];
      seq.start(pcie.rc_seqr(0));
      #1us;
      if (pcie.rejected_writes != 1 || env.sys.router.routed != routed)
        `uvm_error("PCIE_PLUGIN", $sformatf("MAILBOX MemWr: rejected %0d, routed delta %0d",
                   pcie.rejected_writes, env.sys.router.routed - routed))
    endtask
  endclass

  // PCIe 承载的全功能流量：Host0 PF0、Host0 VF1、Host1 PF0；PF0↔Host1 与 VF1↔Host1 各跑一遍
  //   basic_traffic，再检查 MAILBOX 写被拒绝。
  class rdma_env_pcie_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_pcie_test)

    rdma_pcie_plugin pcie;

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_env_pcie_test", uvm_component parent = null);
      super.new(name, parent);
      mem_kind = "host_mem";
    endfunction

    // 功能：在基类配置上改为三个 Function 并加入 PCIe 插件。
    // 输入/输出及副作用：见基类。
    // 失败/边界：无。
    function void build_phase(uvm_phase phase);
      pcie = rdma_pcie_plugin::type_id::create("pcie_plugin");
      super.build_phase(phase);
    endfunction

    // 功能：基类 cfg 建好后、env 创建前由 configure 钩子调整。
    // 输入/输出及副作用：修改 cfg。
    // 失败/边界：无。
    virtual function void configure(rdma_env_cfg c);
      c.funcs.delete();
      c.add_func(0);
      c.add_func(0, 0, DPU_FUNCTION_VF, 1);
      c.add_func(1);
      c.plugins.push_back(pcie);
    endfunction

    // 功能：两段 basic_traffic（f0↔f2、f1↔f2）后检查 MAILBOX。
    // 输入/输出及副作用：启动序列、发 TLP。
    // 失败/边界：见插件。
    virtual task run_traffic();
      rdma_basic_traffic_vseq vseq;

      for (int unsigned f = 0; f < 2; f++) begin
        vseq = rdma_basic_traffic_vseq::type_id::create($sformatf("vseq%0d", f));
        vseq.f0 = f;
        vseq.f1 = 2;
        vseq.start(env.vseqr);
      end
      pcie.check_mailbox(env);
    endtask
  endclass
`endif
`ifdef RDMA_RXE_TEST
  // 与 Linux Soft-RoCE 互打：仿真 Function 0（Host0 PF0）↔ 远端 Function 1（rxe），mock 内存；依次运行
  //   basic_traffic、errors、srq、reliability（URC、远端多 SGE、远端受限 MR、超时类场景由序列跳过）。
  class rdma_env_rxe_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_rxe_test)

    // 功能：构造。
    // 输入/输出及副作用：name/parent 为 UVM 层级。
    // 失败/边界：无。
    function new(string name = "rdma_env_rxe_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 功能：一个仿真 Function 加 rxe 插件（远端 Function）。
    // 输入/输出及副作用：修改 c。
    // 失败/边界：无。
    virtual function void configure(rdma_env_cfg c);
      c.funcs.delete();
      c.add_func(0);
      c.plugins.push_back(rdma_rxe_plugin::type_id::create("rxe_plugin"));
    endfunction

    // 功能：依次运行各场景序列。
    // 输入/输出及副作用：启动序列。
    // 失败/边界：无。
    virtual task run_traffic();
      string names[] = '{"rdma_basic_traffic_vseq", "rdma_errors_vseq", "rdma_srq_vseq",
                         "rdma_reliability_vseq"};

      foreach (names[i]) begin
        vseq_type = names[i];
        super.run_traffic();
      end
    endtask
  endclass
`endif
endpackage
