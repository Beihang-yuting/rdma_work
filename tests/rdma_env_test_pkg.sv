// 目录：测试层 rdma_env_test_pkg.sv。
// 层：测试。
// 职责：env 测试：基类按配置（两 Function：Host0 PF0、Host1 PF0）建立 rdma_env 并运行一个虚拟序列；
//   子类只选链路、内存与序列。+RDMA_LINK=<链路类名>、+RDMA_MEM=mock|host_mem、+RDMA_VSEQ=<序列类名>
//   可覆盖默认值。
// 依赖：rdma_env_pkg、rdma_unit_test_pkg（mock 与真实 host_mem 内存工厂）。
// 所有权：测试拥有配置与 env。
// 生命周期：build 建 env，run_phase 运行序列。
package rdma_env_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import rdma_types_pkg::*;
  import rdma_dpu_adapter_pkg::*;
  import rdma_env_pkg::*;
  import rdma_unit_test_pkg::*;

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
      if (mem_kind == "host_mem")
        cfg.mem_factory = rdma_host_mem_factory::type_id::create("mem_factory");
      else if (mem_kind == "mock")
        cfg.mem_factory = rdma_mock_mem_factory::type_id::create("mem_factory");
      else
        `uvm_fatal("ENV_TEST", {"unknown RDMA_MEM: ", mem_kind})
      uvm_config_db#(rdma_env_cfg)::set(this, "env", "cfg", cfg);
      env = rdma_env::type_id::create("env", this);
    endfunction

    // 功能：按名字创建并运行虚拟序列；scoreboard 须有检查。
    // 输入/输出及副作用：持有 objection 至序列结束。
    // 失败/边界：序列名无效 UVM_FATAL；未检查任何东西报 UVM_ERROR。
    task run_phase(uvm_phase phase);
      uvm_sequence_base vseq;

      phase.raise_objection(this);
      if (!$cast(vseq, uvm_factory::get().create_object_by_name(vseq_type, "", "vseq")))
        `uvm_fatal("ENV_TEST", {"unknown RDMA_VSEQ: ", vseq_type})
      `uvm_info("ENV_TEST", {"link=", link_type, " mem=", mem_kind, " vseq=", vseq_type}, UVM_LOW)
      vseq.start(env.vseqr);
      if (env.sb.checked == 0)
        `uvm_error("ENV_TEST", "scoreboard checked nothing")
      phase.drop_objection(this);
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
endpackage
