// 目录：测试层 rdma_env_test_pkg.sv。
// 层：测试。
// 职责：env 测试：基类按配置（两 Function：Host0 PF0、Host1 PF0）建立 rdma_env 并运行一个虚拟序列；
//   子类只选链路与序列（主机内存恒为外部 host_mem）。+RDMA_LINK=<链路类名>、+RDMA_VSEQ=<序列类名>
//   可覆盖默认值。
//   pcie_work suite 另有 PCIe 插件与 rdma_env_pcie_test；rxe suite 另有 rdma_env_rxe_test。
// 依赖：rdma_drv_pkg、rdma_env_pkg、rdma_unit_test_pkg、pcie_work（可选）。
// 所有权：测试拥有配置与 env。
// 生命周期：build 建 env，run_phase 运行序列。
package rdma_env_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import rdma_types_pkg::*;
  import rdma_codec_pkg::*;
  import rdma_drv_pkg::*;
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
    string vseq_type;

    // 功能：构造 env 测试基类，并选择 loopback 链路与 basic_traffic 作为未覆盖时的默认场景。
    // 输入/输出及副作用：name/parent 建立 UVM 层级；初始化 link_type/vseq_type，不创建 cfg 或 env。
    // 失败/边界：构造阶段不解析 plusarg；派生类可在 super.new 返回后替换两个默认类型名。
    function new(string name = "rdma_env_base_test", uvm_component parent = null);
      super.new(name, parent);
      link_type = "rdma_link";
      vseq_type = "rdma_basic_traffic_vseq";
    endfunction

    // 功能：解析链路/序列 plusarg，建立两 Host 各一 PF 的默认配置，经 configure 后创建测试 env。
    // 输入/输出及副作用：phase 传给基类；创建并持有 cfg/env，向 env 实例写入 config_db。
    // 失败/边界：未知链路由 env factory 创建阶段报告；未知序列延迟到 run_traffic 报 UVM_FATAL。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      void'($value$plusargs("RDMA_LINK=%s", link_type));
      void'($value$plusargs("RDMA_VSEQ=%s", vseq_type));
      cfg = rdma_env_cfg::type_id::create("cfg");
      cfg.add_func(0);
      cfg.add_func(1);
      cfg.link_type = link_type;
      configure(cfg);
      uvm_config_db#(rdma_env_cfg)::set(this, "env", "cfg", cfg);
      env = rdma_env::type_id::create("env", this);
    endfunction

    // 功能：提供派生测试的配置钩子；基类实现保留 build_phase 建立的双 Host 默认拓扑。
    // 输入/输出及副作用：c 为待交给 env 的可变配置；基类不修改它。
    // 失败/边界：调用时 c 必须非空且尚未发布到 config_db；派生实现不得在 env 创建后依赖此钩子。
    virtual function void configure(rdma_env_cfg c);
    endfunction

    // 功能：运行流量；scoreboard 须有检查。
    // 输入/输出及副作用：持有 objection 至流量结束。
    // 失败/边界：未检查任何东西报 UVM_ERROR。
    task run_phase(uvm_phase phase);
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
      uvm_sequence_base vseq;

      if (!$cast(vseq, uvm_factory::get().create_object_by_name(vseq_type, "", "vseq")))
        `uvm_fatal("ENV_TEST", {"unknown RDMA_VSEQ: ", vseq_type})
      vseq.start(env.vseqr);
    endtask
  endclass

  // loopback 链路的全功能流量。
  class rdma_env_basic_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_basic_test)

    // 功能：构造使用默认 loopback/basic_traffic 组合的基础环境测试。
    // 输入/输出及副作用：name/parent 建立 UVM 层级；全部场景选择继承 rdma_env_base_test 默认值。
    // 失败/边界：不增加配置钩子或资源；factory/build 失败沿用基类报告。
    function new(string name = "rdma_env_basic_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction
  endclass

  // net_packet 帧编解码链路的全功能流量。
  class rdma_env_netpkt_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_netpkt_test)

    // 功能：构造经 net_packet 编解码链路运行 basic_traffic 的环境测试。
    // 输入/输出及副作用：name/parent 建立 UVM 层级；把 link_type 覆盖为 rdma_link_netpkt。
    // 失败/边界：不改变默认双 Host 拓扑；net_packet factory/依赖缺失由 env build 报告。
    function new(string name = "rdma_env_netpkt_test", uvm_component parent = null);
      super.new(name, parent);
      link_type = "rdma_link_netpkt";
    endfunction
  endclass

  // net_packet 链路的大流量。
  class rdma_env_high_traffic_test extends rdma_env_netpkt_test;
    `uvm_component_utils(rdma_env_high_traffic_test)

    // 功能：构造在 net_packet 链路上运行 high_traffic 虚拟序列的压力测试。
    // 输入/输出及副作用：name/parent 建立层级；继承 netpkt 链路并覆盖 vseq_type。
    // 失败/边界：流量规模和 drain 超时由 rdma_high_traffic_vseq/env 契约限制，本构造函数不分配流量对象。
    function new(string name = "rdma_env_high_traffic_test", uvm_component parent = null);
      super.new(name, parent);
      vseq_type = "rdma_high_traffic_vseq";
    endfunction
  endclass
  // 错误场景（loopback）。
  class rdma_env_errors_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_errors_test)

    // 功能：构造在默认 loopback 链路上运行 errors 虚拟序列的错误场景测试。
    // 输入/输出及副作用：name/parent 建立层级；仅把 vseq_type 覆盖为 rdma_errors_vseq。
    // 失败/边界：预期错误的降级与断言由序列/scoreboard 负责，本构造函数不放宽 UVM 报告。
    function new(string name = "rdma_env_errors_test", uvm_component parent = null);
      super.new(name, parent);
      vseq_type = "rdma_errors_vseq";
    endfunction
  endclass

  // 可靠传输（netpkt 链路以覆盖 ICRC 丢弃；响应超时编码 8 ≈ 1ms 使超时重传场景可运行）。
  class rdma_env_reliability_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_reliability_test)

    // 功能：构造使用 net_packet 链路和 reliability 序列的重传/超时环境测试。
    // 输入/输出及副作用：name/parent 建立层级；覆盖 link_type 与 vseq_type，尚不修改 cfg 时间参数。
    // 失败/边界：实际响应预算在 configure 设置；构造阶段不启动计时器或持有网络资源。
    function new(string name = "rdma_env_reliability_test", uvm_component parent = null);
      super.new(name, parent);
      link_type = "rdma_link_netpkt";
      vseq_type = "rdma_reliability_vseq";
    endfunction

    // 功能：把可靠性场景的设备响应超时编码设为 8，并把测试等待预算放宽到 1ms。
    // 输入/输出及副作用：修改非空 c.timeout/c.response_timeout，保留其拓扑、重试次数和插件。
    // 失败/边界：仅适用于 env 创建前的配置钩子；空 c 或运行期重配不在本函数契约内。
    virtual function void configure(rdma_env_cfg c);
      c.timeout = 8;
      c.response_timeout = 1ms;
    endfunction
  endclass

  // SRQ 共享（双向）。
  class rdma_env_srq_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_srq_test)

    // 功能：构造运行双向共享接收队列场景的环境测试。
    // 输入/输出及副作用：name/parent 建立层级；把 vseq_type 设为 rdma_srq_vseq，保留 loopback 链路。
    // 失败/边界：SRQ 容量和资源回收由序列检查；构造阶段不创建 SRQ。
    function new(string name = "rdma_env_srq_test", uvm_component parent = null);
      super.new(name, parent);
      vseq_type = "rdma_srq_vseq";
    endfunction
  endclass

  // QP 生命周期（SQD、销毁重建）。
  class rdma_env_lifecycle_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_lifecycle_test)

    // 功能：构造覆盖 SQD、QP 销毁与重建状态迁移的生命周期环境测试。
    // 输入/输出及副作用：name/parent 建立层级；把 vseq_type 设为 rdma_qp_lifecycle_vseq。
    // 失败/边界：状态迁移拒绝与资源泄漏由序列/scoreboard 判定；构造阶段不创建 QP。
    function new(string name = "rdma_env_lifecycle_test", uvm_component parent = null);
      super.new(name, parent);
      vseq_type = "rdma_qp_lifecycle_vseq";
    endfunction
  endclass

  // 多 Function 与复位范围：Host0 PF0、Host0 VF1、Host1 PF0、Host1 VF1。
  class rdma_env_multifunc_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_multifunc_test)

    // 功能：构造覆盖跨 Host PF/VF authority 与复位隔离的多 Function 环境测试。
    // 输入/输出及副作用：name/parent 建立层级；选择 rdma_multifunc_vseq，拓扑稍后由 configure 重建。
    // 失败/边界：构造后 cfg 尚不存在；调用方不能在 build_phase 前读取四 Function 拓扑。
    function new(string name = "rdma_env_multifunc_test", uvm_component parent = null);
      super.new(name, parent);
      vseq_type = "rdma_multifunc_vseq";
    endfunction

    // 功能：把默认拓扑替换为 Host0/Host1 各一个 PF0 与 VF1，供多 Function 序列验证隔离。
    // 输入/输出及副作用：清空 c.funcs 后按稳定顺序加入四个 Function；其他配置字段保持不变。
    // 失败/边界：c 必须非空且尚未冻结；重复调用先清空列表，因此拓扑结果幂等。
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

    // 功能：构造在 net_packet 链路上运行随机事务组合的环境测试。
    // 输入/输出及副作用：name/parent 建立层级；覆盖 link_type 与 vseq_type，不预生成随机 item。
    // 失败/边界：随机约束失败由 rdma_random_vseq 报告；种子由仿真器/runner 管理。
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
    bit allow_device_errors;

    // 功能：构造尚未建立 PCIe 系统的 env 插件，默认要求所有设备 MMIO 处理成功。
    // 输入/输出及副作用：name 传给 rdma_env_plugin；pcie 置空，allow_device_errors 清零。
    // 失败/边界：pre_build/build 由 env 生命周期调用；负向测试须显式置 allow_device_errors。
    function new(string name = "rdma_pcie_plugin");
      super.new(name);
      pcie = null;
      allow_device_errors = 1'b0;
    endfunction

    // 功能：在 dpu 系统创建 BAR/DMA 对象前安装 pcie_work 前门及 RC/EP 驱动 factory 覆盖。
    // 输入/输出及副作用：env 仅提供生命周期定位；修改 UVM factory 的四个 type override。
    // 失败/边界：必须由 rdma_env.build_phase 在 build_system 前调用，重复安装保持相同映射。
    virtual function void pre_build(rdma_env env);
      rdma_pcie_system::install_overrides();
    endfunction

    // 功能：创建 env 子组件 rdma_pcie_system，并把冻结 dpu 系统与每 Host host_mem 借给它。
    // 输入/输出及副作用：env 为父组件；pcie 保存拥有的组件引用，host_mems 复制非拥有 manager 句柄表。
    // 失败/边界：env.sys 必须已 build；缺 Host memory 或快照问题由 pcie.build_phase 报 UVM_FATAL。
    virtual function void build(rdma_env env);
      pcie = rdma_pcie_system::type_id::create("pcie", env);
      pcie.dpu = env.sys;
      pcie.host_mems = env.sys.mems.managers;
    endfunction

    // 功能：结束时联合检查 RDMA PCIe 事务计数、Function requester authority、MMIO 结算、FC 边界、
    //   每 Root 事务记分板和功能覆盖采样，证明验证组件不是仅配置而未参与流量。
    // 输入/输出及副作用：env 提供 Function/BAR 审计；只读 pcie/tl_env 状态，违约时报告 UVM_ERROR。
    // 失败/边界：跨 Host MMIO authority 探针要求恰好一个 rejected；正常测试不允许 failed_writes，负向测试可设置
    //   allow_device_errors，但 decoded+failed 仍须结算全部已路由 BAR 写。
    virtual function void report(rdma_env env);
      int unsigned seen;
      int unsigned recorded;
      bit [47:0] requester_key;
      pcie_tl_fc_manager fc;
      pcie_tl_scoreboard scb;
      int unsigned active_pending;

      `uvm_info("PCIE_PLUGIN", $sformatf("DMA TLPs: MemRd %0d/%0d, MemWr %0d/%0d (EP/RC)",
                pcie.dma_read_tlps, pcie.host_reads, pcie.dma_write_tlps, pcie.host_writes),
                UVM_LOW)
      if (pcie.dma_read_tlps == 0 || pcie.dma_write_tlps == 0 ||
          pcie.host_reads != pcie.dma_read_tlps || pcie.host_writes != pcie.dma_write_tlps ||
          pcie.dma_read_successes + pcie.dma_read_failures != pcie.dma_read_tlps)
        `uvm_error("PCIE_PLUGIN", $sformatf(
          {"device DMA accounting differs: reads sent/host/success/failure=%0d/%0d/%0d/%0d ",
           "writes sent/host=%0d/%0d"},
          pcie.dma_read_tlps, pcie.host_reads, pcie.dma_read_successes,
          pcie.dma_read_failures, pcie.dma_write_tlps, pcie.host_writes))
      seen = 0;
      recorded = 0;
      foreach (env.sys.nodes[i]) begin
        recorded += env.sys.nodes[i].bar.written_offsets.size();
        requester_key = {env.sys.nodes[i].func.key.host_id, env.sys.nodes[i].func.pcie_id.bdf};
        if (!pcie.host_requesters.exists(requester_key))
          `uvm_error("PCIE_PLUGIN", $sformatf("f%0d Host %0d BDF %04h issued no DMA", i,
                     env.sys.nodes[i].func.key.host_id,
                     env.sys.nodes[i].func.pcie_id.bdf))
        else
          seen += pcie.host_requesters[requester_key];
      end
      if (seen != pcie.host_reads + pcie.host_writes)
        `uvm_error("PCIE_PLUGIN", "RC served DMA requests from an unknown requester ID")
      if (recorded == 0 || pcie.sent_writes != recorded ||
          pcie.decoded_writes + pcie.failed_writes != recorded || pcie.rejected_writes != 1)
        `uvm_error("PCIE_PLUGIN", $sformatf(
          "BAR writes %0d, TLPs %0d, decoded %0d, failed %0d, rejected %0d",
          recorded, pcie.sent_writes, pcie.decoded_writes, pcie.failed_writes,
          pcie.rejected_writes))
      if (!allow_device_errors && pcie.failed_writes != 0)
        `uvm_error("PCIE_PLUGIN", $sformatf("unexpected device-side MMIO failures: %0d",
                   pcie.failed_writes))
      if (!pcie.tl_cfg.fc_enable || !pcie.tl_cfg.scb_enable || !pcie.tl_cfg.cov_enable ||
          !pcie.tl_cfg.tlp_basic_cov || !pcie.tl_cfg.fc_state_cov ||
          !pcie.tl_cfg.tag_usage_cov || !pcie.tl_cfg.ordering_cov ||
          !pcie.tl_cfg.error_inject_cov)
        `uvm_error("PCIE_PLUGIN", "PCIe FC, scoreboard, or coverage policy is disabled")
      foreach (pcie.tl_env.fc_mgrs[r]) begin
        fc = pcie.tl_env.fc_mgrs[r];
        if (fc.posted_header.current > fc.posted_header.limit ||
            fc.posted_data.current > fc.posted_data.limit ||
            fc.non_posted_header.current > fc.non_posted_header.limit ||
            fc.non_posted_data.current > fc.non_posted_data.limit ||
            fc.completion_header.current > fc.completion_header.limit ||
            fc.completion_data.current > fc.completion_data.limit)
          `uvm_error("PCIE_PLUGIN", $sformatf("Root %0d flow-control credit escaped its limit", r))
      end
      foreach (pcie.tl_env.scbs[r]) begin
        scb = pcie.tl_env.scbs[r];
        active_pending = 0;
        if (scb != null)
          foreach (scb.pending_requests[tag])
            if (scb.pending_requests[tag] == null || !scb.pending_requests[tag].rb_done)
              active_pending++;
        if (scb == null || scb.total_requests == 0 || scb.total_completions == 0 ||
            scb.matched == 0 || scb.mismatched != 0 || scb.unexpected != 0 ||
            active_pending != 0 || scb.cpl_trackers.size() != 0)
          `uvm_error("PCIE_PLUGIN", $sformatf(
            {"Root %0d scoreboard requests=%0d completions=%0d matched=%0d ",
             "mismatched=%0d unexpected=%0d pending=%0d active=%0d trackers=%0d"},
            r, scb == null ? 0 : scb.total_requests,
            scb == null ? 0 : scb.total_completions, scb == null ? 0 : scb.matched,
            scb == null ? 0 : scb.mismatched, scb == null ? 0 : scb.unexpected,
            scb == null ? 0 : scb.pending_requests.size(),
            active_pending,
            scb == null ? 0 : scb.cpl_trackers.size()))
        if (pcie.tl_env.tag_mgrs[r].get_outstanding_count() != 0)
          `uvm_error("PCIE_PLUGIN", $sformatf("Root %0d leaked %0d PCIe tags", r,
                     pcie.tl_env.tag_mgrs[r].get_outstanding_count()))
      end
      if (pcie.tl_env.cov == null || pcie.tl_env.cov.sampled_tlp == null)
        `uvm_error("PCIE_PLUGIN", "PCIe functional coverage collector sampled no TLP")
    endfunction

    // 功能：从 Host1 RC 访问只属于 Host0 domain 的 BAR0 doorbell 地址，证明 EP ingress authority 禁止
    //   适配层遍历其他 domain 猜测目标。
    // 输入/输出及副作用：env 提供 Host0 地址与 Host1 Root；发送一个 8B posted MemWr，等待分派，并确认
    //   router 与所有设备 doorbell 均未改变、rejected 恰增一。
    // 失败/边界：要求默认 PCIe fixture 至少有两个 Host 且 Host0 地址在 Host1 domain 不可解析；fixture
    //   不满足、写被跨 Host 路由或 1us 内未结算时报告 UVM_ERROR。
    task check_cross_host_mmio(rdma_env env);
      pcie_tl_rw_seq seq;
      int unsigned routed;
      int unsigned rejected;
      int unsigned doorbells[$];
      dpu_bar_address_match_t match;
      string why;
      bit [63:0] address;
      int unsigned ingress_host;

      if (env.sys.nodes.size() < 3) begin
        `uvm_error("PCIE_PLUGIN", "cross-Host MMIO probe requires the three-Function fixture")
        return;
      end
      ingress_host = env.sys.nodes[2].func.key.host_id;
      address = env.sys.nodes[0].func.bar0.base + RDMA_NOTIFY_WINDOW_OFFSET +
                RDMA_DB_CEQ_OFFSET;
      if (env.sys.snapshot.resolve_bar_address(env.sys.nodes[2].func.pcie_id.domain,
                                               address, match, why)) begin
        `uvm_error("PCIE_PLUGIN", {"cross-Host MMIO probe address is valid in ingress domain: ",
                   why})
        return;
      end
      routed = env.sys.router.routed;
      rejected = pcie.rejected_writes;
      foreach (env.sys.nodes[i])
        doorbells.push_back(env.sys.nodes[i].dev.doorbell_offsets.size());
      seq = pcie_tl_rw_seq::type_id::create("cross_host_mmio_wr");
      seq.op = PCIE_RW_WRITE;
      seq.addr = address;
      seq.byte_len = 8;
      seq.wdata = new[8];
      seq.start(pcie.rc_seqr(ingress_host));
      #1us;
      if (pcie.rejected_writes != rejected + 1 || env.sys.router.routed != routed)
        `uvm_error("PCIE_PLUGIN", $sformatf(
          "cross-Host MMIO: rejected delta %0d, routed delta %0d",
          pcie.rejected_writes - rejected, env.sys.router.routed - routed))
      foreach (env.sys.nodes[i])
        if (env.sys.nodes[i].dev.doorbell_offsets.size() != doorbells[i])
          `uvm_error("PCIE_PLUGIN", $sformatf(
            "cross-Host MMIO changed f%0d doorbell count from %0d to %0d", i, doorbells[i],
            env.sys.nodes[i].dev.doorbell_offsets.size()))
    endtask
  endclass

  // PCIe 承载的全功能流量：Host0 PF0、Host0 VF1、Host1 PF0；PF0↔Host1 与 VF1↔Host1 各跑一遍
  //   basic_traffic，再检查 Host1 不能把 Host0 BAR 地址跨 domain 路由。
  class rdma_env_pcie_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_pcie_test)

    rdma_pcie_plugin pcie;

    // 功能：构造使用三 Function PCIe 拓扑和 pcie_work 插件的正向环境测试。
    // 输入/输出及副作用：name/parent 建立层级；pcie 在 build_phase 前保持空引用。
    // 失败/边界：直接实例化后尚未安装 factory override，必须让 UVM 正常进入 build_phase。
    function new(string name = "rdma_env_pcie_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 功能：先创建 PCIe 插件，再让基类建立 cfg/env，确保 configure 能把同一插件引用发布给 env。
    // 输入/输出及副作用：phase 传给基类；创建并持有 pcie，随后创建 cfg 与 env。
    // 失败/边界：插件 factory 返回空或 env 构建失败由 UVM factory/build 报告；不得颠倒创建顺序。
    function void build_phase(uvm_phase phase);
      pcie = rdma_pcie_plugin::type_id::create("pcie_plugin");
      super.build_phase(phase);
    endfunction

    // 功能：把默认双 PF 拓扑改为 Host0 PF0/VF1 与 Host1 PF0，并安装已创建的 PCIe 插件。
    // 输入/输出及副作用：重建 c.funcs、向 c.plugins 追加 pcie；插件随后建立每 Host PCIe 链路。
    // 失败/边界：要求 c/pcie 非空且 env 尚未创建；重复调用会再次追加插件，不属于幂等入口。
    virtual function void configure(rdma_env_cfg c);
      c.funcs.delete();
      c.add_func(0);
      c.add_func(0, 0, DPU_FUNCTION_VF, 1);
      c.add_func(1);
      c.plugins.push_back(pcie);
    endfunction

    // 功能：依次运行 f0↔f2、f1↔f2 两段 basic_traffic，再发送跨 Host MMIO authority 探针。
    // 输入/输出及副作用：为每段创建独立 vseq 并在 env.vseqr 上启动，最后更新 PCIe 拒绝观测。
    // 失败/边界：序列或跨 Host 结算异常报告 UVM_ERROR/FATAL；两段严格串行，不留下并发在途流量。
    virtual task run_traffic();
      rdma_basic_traffic_vseq vseq;

      for (int unsigned f = 0; f < 2; f++) begin
        vseq = rdma_basic_traffic_vseq::type_id::create($sformatf("vseq%0d", f));
        vseq.f0 = f;
        vseq.f1 = 2;
        vseq.start(env.vseqr);
      end
      pcie.check_cross_host_mmio(env);
    endtask
  endclass
  `include "integration/rdma_pcie_fault_test.sv"
`endif
`ifdef RDMA_RXE_TEST
  // 与 Linux Soft-RoCE 互打：仿真 Function 0（Host0 PF0）↔ 远端 Function 1（rxe）；依次运行
  //   basic_traffic、errors、srq、reliability（URC、远端多 SGE、远端受限 MR、超时类场景由序列跳过）。
  class rdma_env_rxe_test extends rdma_env_base_test;
    `uvm_component_utils(rdma_env_rxe_test)

    // 功能：构造一个仿真 Function 与一个 Soft-RoCE 远端 Function 互通的环境测试。
    // 输入/输出及副作用：name/parent 建立层级；沿用基类默认类型，拓扑和插件在 configure 设置。
    // 失败/边界：构造阶段不检查 TAP/rxe 设备；缺少外部环境由 rxe 插件启动阶段报告。
    function new(string name = "rdma_env_rxe_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 功能：把默认拓扑缩为 Host0 PF0，并加入负责一个远端 Function 的 rxe 插件。
    // 输入/输出及副作用：清空并重建 c.funcs，向 c.plugins 追加新插件；其余链路参数保持不变。
    // 失败/边界：c 必须非空且尚未发布；重复调用会追加重复插件，因此只允许基类 build 调用一次。
    virtual function void configure(rdma_env_cfg c);
      c.funcs.delete();
      c.add_func(0);
      c.plugins.push_back(rdma_rxe_plugin::type_id::create("rxe_plugin"));
    endfunction

    // 功能：在同一 rxe 环境依次运行 basic、errors、srq、reliability 四种虚拟序列。
    // 输入/输出及副作用：逐项更新 vseq_type，并复用基类 run_traffic 在 env.vseqr 上启动序列。
    // 失败/边界：任一类型未注册会由基类报 UVM_FATAL；严格串行，后一场景可观察前一场景保留的环境状态。
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
