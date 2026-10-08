// 目录：测试层 tests/integration/rdma_pcie_fault_test.sv。
// 层：PCIe 集成负向测试。
// 职责：在真实 rdma_env_pcie_test 拓扑中注入设备 MemRd Completion timeout、UR 与 CA，校验设备
//   DMA 的结构化 rdma_status、适配层错误账本、tag/事务记分板结算，以及 CMQ 驱动可观察超时。
// 依赖：rdma_env_test_pkg 已定义的 rdma_env_pcie_test/rdma_pcie_plugin、rdma_pcie_work_pkg 与 UVM。
// 所有权与生命周期：测试只拥有 report catcher 和临时 driver DMA buffer；PCIe/dpu/host_mem 由 env 持有，
//   catcher 在负向事务结束后注销，buffer 在同一 run_traffic 内释放。

// 负向 Completion 会由外部 pcie_tl_rw_seq 报 warning/error；本 catcher 只在明确注入窗口内把这些
// 预期报告降为 info，并计数证明每个 fault 确实走过外部序列的可观察失败路径。
class rdma_pcie_expected_report_catcher extends uvm_report_catcher;
  int unsigned completion_reports;
  int unsigned timeout_reports;
  rdma_pcie_fault_e expected_fault;
  bit expectation_active;

  // 功能：构造尚未捕获任何预期 PCIe 报告的 catcher。
  // 输入/输出及副作用：name 传给 uvm_report_catcher；两个计数清零。
  // 失败/边界：对象创建后仍须经 uvm_report_cb::add 注册，未注册不会影响全局报告。
  function new(string name = "rdma_pcie_expected_report_catcher");
    super.new(name);
    completion_reports = 0;
    timeout_reports = 0;
    expected_fault = RDMA_PCIE_FAULT_NONE;
    expectation_active = 1'b0;
  endfunction

  // 功能：登记下一条设备读唯一允许降级的 RW_SEQ 报告类型，使 catcher 与当前 fault 操作绑定。
  // 输入/输出及副作用：fault 必须为 timeout/UR/CA；保存 expected_fault 并置 expectation_active。
  // 失败/边界：NONE 或前一个期望尚未消费时报告 UVM_ERROR，且不覆盖在途期望。
  function void arm_expectation(rdma_pcie_fault_e fault);
    if (fault == RDMA_PCIE_FAULT_NONE || expectation_active) begin
      `uvm_error("PCIE_FAULT_CATCHER", $sformatf(
        "cannot arm report expectation current=%s next=%s",
        expected_fault.name(), fault.name()))
      return;
    end
    expected_fault = fault;
    expectation_active = 1'b1;
  endfunction

  // 功能：确认当前 fault 已产生并消费唯一匹配的外部 RW_SEQ 报告。
  // 输入/输出及副作用：label 仅用于诊断；若仍 active 则报告错误，不修改累计计数。
  // 失败/边界：必须在对应 dma.read 返回后调用；未先 arm_expectation 也会被视为未消费期望。
  function void check_consumed(string label);
    if (expectation_active)
      `uvm_error("PCIE_FAULT_CATCHER", $sformatf(
        "%s did not emit expected %s RW_SEQ report", label, expected_fault.name()))
  endfunction

  // 功能：只降级当前 arm_expectation 声明的 RW_SEQ timeout 或指定 UR/CA Completion 报告。
  // 输入/输出及副作用：核对 id、severity 与消息中的精确状态；命中后累计计数、清除 active 并改为 INFO。
  // 失败/边界：窗口外、重复报告或状态/消息不符均原样 THROW，使非预期 warning/error 保持测试失败。
  virtual function action_e catch();
    bit matched;

    matched = 1'b0;
    if (!expectation_active || get_id() != "RW_SEQ")
      return THROW;
    case (expected_fault)
      RDMA_PCIE_FAULT_TIMEOUT:
        matched = get_severity() == UVM_ERROR &&
                  uvm_is_match("READ timeout:*", get_message());
      RDMA_PCIE_FAULT_UR:
        matched = get_severity() == UVM_WARNING &&
                  uvm_is_match("READ completed with status=CPL_STATUS_UR *", get_message());
      RDMA_PCIE_FAULT_CA:
        matched = get_severity() == UVM_WARNING &&
                  uvm_is_match("READ completed with status=CPL_STATUS_CA *", get_message());
      default:
        matched = 1'b0;
    endcase
    if (!matched)
      return THROW;
    if (expected_fault inside {RDMA_PCIE_FAULT_UR, RDMA_PCIE_FAULT_CA})
      completion_reports++;
    else
      timeout_reports++;
    expected_fault = RDMA_PCIE_FAULT_NONE;
    expectation_active = 1'b0;
    set_severity(UVM_INFO);
    return THROW;
  endfunction
endclass

// 先制造双 Root 同 BDF/tag 的 timeout 碰撞，再运行完整 PCIe basic traffic并用同一设备 DMA 前门
// 逐项验证 timeout/UR/CA；最后把 UR 注入真实 CMQ SQE fetch，证明设备保存 PCIe 根因。
class rdma_env_pcie_fault_test extends rdma_env_pcie_test;
  `uvm_component_utils(rdma_env_pcie_fault_test)

  rdma_pcie_expected_report_catcher catcher;

  // 功能：构造 PCIe fault 集成测试，拓扑与正向 rdma_env_pcie_test 完全一致。
  // 输入/输出及副作用：name/parent 传给基类，不提前创建 env 或注入规则。
  // 失败/边界：build_phase 前 pcie 插件仍为空；碰撞 fault 在正向流量前运行，其余 fault 在排空后安排。
  function new(string name = "rdma_env_pcie_fault_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：沿用基类创建 PCIe 插件/env，并声明本测试允许一个预期的设备侧 MMIO 失败。
  // 输入/输出及副作用：phase 传给基类；设置 pcie.allow_device_errors，供 report 接受 CMQ fault。
  // 失败/边界：基类 build 失败时保持 UVM_FATAL；该开关不放宽事务记分板、FC 或计数守恒检查。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    pcie.allow_device_errors = 1'b1;
  endfunction

  // 功能：先验证双 Root registry 隔离，再运行正向流量，并验证直接设备 DMA 与驱动 CMQ 的错误传播。
  // 输入/输出及副作用：注册临时 catcher，碰撞测试后申请 64B Host DMA buffer，累计六条故障 MemRd。
  // 失败/边界：buffer、fault、状态、计数或释放任一不符报告 UVM_ERROR；catcher 始终在返回前注销。
  virtual task run_traffic();
    rdma_drv_dma buffer;
    rdma_status status;

    catcher = new("expected_pcie_reports");
    uvm_report_cb::add(null, catcher);
    check_cross_root_registry_isolation();
    pcie.pcie.dma_completion_timeout_ns = 50000;
    super.run_traffic();
    pcie.pcie.dma_completion_timeout_ns = 200;
    status = env.sys.nodes[0].hw.alloc_dma(64, 64, buffer);
    if (!status.ok()) begin
      `uvm_error("PCIE_FAULT", {"failed to allocate fault buffer: ", status.convert2string()})
      uvm_report_cb::delete(null, catcher);
      return;
    end

    check_direct_fault(RDMA_PCIE_FAULT_UR, RDMA_SC_PCIE_COMPLETION, 1'b1,
                       CPL_STATUS_UR, 1'b0, buffer.iova);
    check_direct_fault(RDMA_PCIE_FAULT_CA, RDMA_SC_PCIE_COMPLETION, 1'b1,
                       CPL_STATUS_CA, 1'b0, buffer.iova);
    check_direct_fault(RDMA_PCIE_FAULT_TIMEOUT, RDMA_SC_TIMEOUT, 1'b0,
                       CPL_STATUS_SC, 1'b1, buffer.iova);
    check_driver_fault();

    status = env.sys.nodes[0].hw.free_dma(buffer);
    if (!status.ok())
      `uvm_error("PCIE_FAULT", {"failed to free fault buffer: ", status.convert2string()})
    uvm_report_cb::delete(null, catcher);
    if (catcher.completion_reports != 3 || catcher.timeout_reports != 3)
      `uvm_error("PCIE_FAULT", $sformatf(
        "expected three Completion reports and three timeout reports, got %0d/%0d",
        catcher.completion_reports, catcher.timeout_reports))
  endtask

  // 功能：让 Host0 PF0 与 Host1 PF0 使用相同 BDF/tag 发起两条不返回 Completion 的 MemRd，先退休
  //   Root0，再证明 Root1 的同键 registry/sequence 未被唤醒，最终独立超时退休。
  // 输入/输出及副作用：重排两个 func0 tag pool 的一个共同 tag，申请并释放各 Host 16B buffer；发两条
  //   原始 PCIe 序列，更新系统读/失败账本、scoreboard timed_out 与两个 EP quarantine。
  // 失败/边界：要求三 Function 双 Host fixture、相同 PF0 BDF、两个 pool 有共同空闲 tag；对象、tag、
  //   registry 或资源结算不符报告 UVM_ERROR，注入状态不对称或序列无法在预算内完成时 UVM_FATAL。
  protected task check_cross_root_registry_isolation();
    rdma_pcie_dma_seq seq0;
    rdma_pcie_dma_seq seq1;
    rdma_pcie_ep_driver ep0;
    rdma_pcie_ep_driver ep1;
    pcie_tl_tag_manager tag_mgr0;
    pcie_tl_tag_manager tag_mgr1;
    rdma_drv_dma buffer0;
    rdma_drv_dma buffer1;
    rdma_status status;
    rdma_status timeout_status;
    int unsigned root0;
    int unsigned root1;
    int pool0;
    int pool1;
    int index0;
    int index1;
    bit found;
    bit done0;
    bit done1;
    bit issued0;
    bit issued1;
    bit [9:0] collision_tag;
    bit [25:0] registry_key;

    if (env.sys.nodes.size() < 3 ||
        env.sys.nodes[0].func.pcie_id.bdf != env.sys.nodes[2].func.pcie_id.bdf) begin
      `uvm_error("PCIE_FAULT", "cross-Root registry probe requires Host0/Host1 PF0 with equal BDF")
      return;
    end
    if (!pcie.pcie.host_root.exists(env.sys.nodes[0].func.key.host_id) ||
        !pcie.pcie.host_root.exists(env.sys.nodes[2].func.key.host_id)) begin
      `uvm_error("PCIE_FAULT", "cross-Root registry probe lacks a Host-to-Root binding")
      return;
    end
    root0 = pcie.pcie.host_root[env.sys.nodes[0].func.key.host_id];
    root1 = pcie.pcie.host_root[env.sys.nodes[2].func.key.host_id];
    if (root0 >= pcie.pcie.tl_env.tag_mgrs.size() ||
        root1 >= pcie.pcie.tl_env.tag_mgrs.size() ||
        root0 >= pcie.pcie.tl_env.ep_agents.size() ||
        root1 >= pcie.pcie.tl_env.ep_agents.size() || root0 == root1) begin
      `uvm_error("PCIE_FAULT", "cross-Root registry probe lacks tag managers or RDMA EP drivers")
      return;
    end
    tag_mgr0 = pcie.pcie.tl_env.tag_mgrs[root0];
    tag_mgr1 = pcie.pcie.tl_env.tag_mgrs[root1];
    if (tag_mgr0 == null || tag_mgr1 == null ||
        pcie.pcie.tl_env.ep_agents[root0] == null ||
        pcie.pcie.tl_env.ep_agents[root1] == null ||
        !$cast(ep0, pcie.pcie.tl_env.ep_agents[root0].ep_driver) ||
        !$cast(ep1, pcie.pcie.tl_env.ep_agents[root1].ep_driver)) begin
      `uvm_error("PCIE_FAULT",
                 "cross-Root registry probe has null or non-RDMA verification objects")
      return;
    end
    pool0 = env.sys.nodes[0].func.pcie_id.bdf[2:0];
    pool1 = env.sys.nodes[2].func.pcie_id.bdf[2:0];
    if (!tag_mgr0.tag_pool.exists(pool0))
      pool0 = 0;
    if (!tag_mgr1.tag_pool.exists(pool1))
      pool1 = 0;
    found = 1'b0;
    if (tag_mgr0.tag_pool.exists(pool0) && tag_mgr1.tag_pool.exists(pool1)) begin
      foreach (tag_mgr0.tag_pool[pool0][i]) begin
        foreach (tag_mgr1.tag_pool[pool1][j]) begin
          if (tag_mgr0.tag_pool[pool0][i] == tag_mgr1.tag_pool[pool1][j]) begin
            collision_tag = tag_mgr0.tag_pool[pool0][i];
            index0 = i;
            index1 = j;
            found = 1'b1;
            break;
          end
        end
        if (found)
          break;
      end
    end
    if (!found) begin
      `uvm_error("PCIE_FAULT", "cross-Root registry probe found no common available tag")
      return;
    end
    tag_mgr0.tag_pool[pool0].delete(index0);
    tag_mgr0.tag_pool[pool0].push_front(collision_tag);
    tag_mgr1.tag_pool[pool1].delete(index1);
    tag_mgr1.tag_pool[pool1].push_front(collision_tag);

    status = env.sys.nodes[0].hw.alloc_dma(16, 16, buffer0);
    if (!status.ok()) begin
      `uvm_error("PCIE_FAULT", {"Host0 collision buffer allocation failed: ",
                 status.convert2string()})
      return;
    end
    status = env.sys.nodes[2].hw.alloc_dma(16, 16, buffer1);
    if (!status.ok()) begin
      `uvm_error("PCIE_FAULT", {"Host1 collision buffer allocation failed: ",
                 status.convert2string()})
      void'(env.sys.nodes[0].hw.free_dma(buffer0));
      return;
    end

    seq0 = rdma_pcie_dma_seq::type_id::create("cross_root_timeout0");
    seq0.op = PCIE_RW_READ;
    seq0.addr = buffer0.iova;
    seq0.byte_len = 16;
    seq0.requester_id = env.sys.nodes[0].func.pcie_id.bdf;
    seq0.rb_timeout_ns = 200;
    seq1 = rdma_pcie_dma_seq::type_id::create("cross_root_timeout1");
    seq1.op = PCIE_RW_READ;
    seq1.addr = buffer1.iova;
    seq1.byte_len = 16;
    seq1.requester_id = env.sys.nodes[2].func.pcie_id.bdf;
    seq1.rb_timeout_ns = 1000;
    status = pcie.pcie.arm_read_fault(env.sys.nodes[0].func, RDMA_PCIE_FAULT_TIMEOUT);
    if (!status.ok()) begin
      `uvm_error("PCIE_FAULT", {"could not arm Host0 collision timeout: ",
                 status.convert2string()})
      void'(env.sys.nodes[0].hw.free_dma(buffer0));
      void'(env.sys.nodes[2].hw.free_dma(buffer1));
      return;
    end
    status = pcie.pcie.arm_read_fault(env.sys.nodes[2].func, RDMA_PCIE_FAULT_TIMEOUT);
    if (!status.ok()) begin
      void'(env.sys.nodes[0].hw.free_dma(buffer0));
      void'(env.sys.nodes[2].hw.free_dma(buffer1));
      `uvm_fatal("PCIE_FAULT", {"could not arm Host1 collision timeout after Host0 was armed: ",
                 status.convert2string()})
    end

    done0 = 1'b0;
    done1 = 1'b0;
    pcie.pcie.dma_read_tlps += 2;
    catcher.arm_expectation(RDMA_PCIE_FAULT_TIMEOUT);
    fork
      begin
        seq0.start(pcie.pcie.ep_seqr(env.sys.nodes[0].func.key.host_id));
        done0 = 1'b1;
      end
    join_none
    issued0 = 1'b0;
    for (int unsigned n = 0; n < 100 && !issued0; n++) begin
      #1ns;
      issued0 = seq0.rdma_issued_tlp != null;
    end
    if (!issued0)
      `uvm_fatal("PCIE_FAULT", "Host0 collision request was not issued within 100ns")
    if (seq0.rdma_issued_tlp.tag != collision_tag)
      `uvm_error("PCIE_FAULT", "Host0 did not issue the selected collision tag")

    fork
      begin
        seq1.start(pcie.pcie.ep_seqr(env.sys.nodes[2].func.key.host_id));
        done1 = 1'b1;
      end
    join_none
    issued1 = 1'b0;
    for (int unsigned n = 0; n < 100 && !issued1; n++) begin
      #1ns;
      issued1 = seq1.rdma_issued_tlp != null;
    end
    if (!issued1)
      `uvm_fatal("PCIE_FAULT", "Host1 collision request was not issued within 100ns")
    registry_key = pcie_rb_registry::mk_key(seq0.requester_id, collision_tag);
    if (seq1.rdma_issued_tlp.tag != collision_tag)
      `uvm_error("PCIE_FAULT", "Host1 did not issue the selected collision tag")
    if (!pcie_rb_registry::reqs.exists(registry_key))
      `uvm_error("PCIE_FAULT", "Host1 collision request did not register its global key")
    else if (pcie_rb_registry::reqs[registry_key] != seq1.rdma_issued_tlp)
      `uvm_error("PCIE_FAULT", "Host1 did not own the colliding global registry key")

    for (int unsigned n = 0; n < 2000 && !done0; n++)
      #1ns;
    if (!done0)
      `uvm_fatal("PCIE_FAULT", "Host0 collision sequence did not terminate within 2us")
    catcher.check_consumed("cross-Root Host0 timeout");
    catcher.arm_expectation(RDMA_PCIE_FAULT_TIMEOUT);
    if (seq0.status != PCIE_RW_TIMEOUT)
      `uvm_error("PCIE_FAULT", $sformatf("Host0 collision status was %s", seq0.status.name()))
    pcie.pcie.retire_timed_out_read(env.sys.nodes[0].func, seq0.rdma_issued_tlp);
    timeout_status = rdma_status::make(RDMA_SC_TIMEOUT, "cross-Root Host0 PCIe timeout");
    timeout_status.retryable = 1'b1;
    timeout_status.source_engine = RDMA_ENGINE_PCIE;
    timeout_status.function_uid = env.sys.nodes[0].func.global_id;
    pcie.pcie.record_dma_error(env.sys.nodes[0].func, timeout_status);
    #1ns;
    if (done1)
      `uvm_error("PCIE_FAULT", "Host1 collision request finished before its independent timeout")
    if (!pcie_rb_registry::reqs.exists(registry_key))
      `uvm_error("PCIE_FAULT", "Host0 timeout deleted Host1 colliding registry request")
    else if (pcie_rb_registry::reqs[registry_key] != seq1.rdma_issued_tlp)
      `uvm_error("PCIE_FAULT", "Host0 timeout disturbed Host1 colliding registry request")

    for (int unsigned n = 0; n < 2000 && !done1; n++)
      #1ns;
    if (!done1)
      `uvm_fatal("PCIE_FAULT", "Host1 collision sequence did not terminate within 2us")
    catcher.check_consumed("cross-Root Host1 timeout");
    if (seq1.status != PCIE_RW_TIMEOUT)
      `uvm_error("PCIE_FAULT", $sformatf("Host1 collision status was %s", seq1.status.name()))
    pcie.pcie.retire_timed_out_read(env.sys.nodes[2].func, seq1.rdma_issued_tlp);
    timeout_status = rdma_status::make(RDMA_SC_TIMEOUT, "cross-Root Host1 PCIe timeout");
    timeout_status.retryable = 1'b1;
    timeout_status.source_engine = RDMA_ENGINE_PCIE;
    timeout_status.function_uid = env.sys.nodes[2].func.global_id;
    pcie.pcie.record_dma_error(env.sys.nodes[2].func, timeout_status);
    if (pcie_rb_registry::reqs.exists(registry_key) ||
        !ep0.timeout_quarantine.exists(registry_key) ||
        !ep1.timeout_quarantine.exists(registry_key) ||
        !tag_pool_unique(tag_mgr0, pool0) || !tag_pool_unique(tag_mgr1, pool1))
      `uvm_error("PCIE_FAULT", "cross-Root collision retirement left registry/tag corruption")

    status = env.sys.nodes[0].hw.free_dma(buffer0);
    if (!status.ok())
      `uvm_error("PCIE_FAULT", {"Host0 collision buffer release failed: ",
                 status.convert2string()})
    status = env.sys.nodes[2].hw.free_dma(buffer1);
    if (!status.ok())
      `uvm_error("PCIE_FAULT", {"Host1 collision buffer release failed: ",
                 status.convert2string()})
  endtask

  // 功能：给 Function0 下一条设备 MemRd 注入指定 fault，并验证设备接口返回的完整 rdma_status 与账本。
  // 输入/输出及副作用：fault/expected_* 描述期望，iova 指向已分配 buffer；发 16B 读并更新 PCIe 计数。
  // 失败/边界：非预期成功、残留数据、错误分类/硬件码/引擎/Function/retryable 或事务计数不守恒均报错。
  protected task check_direct_fault(rdma_pcie_fault_e fault, rdma_status_code_e expected_code,
                                    bit hardware_valid, cpl_status_e hardware_code,
                                    bit retryable, bit [63:0] iova);
    rdma_pcie_dma dma;
    rdma_pcie_ep_driver ep_driver;
    rdma_status status;
    rdma_status observed;
    pcie_tl_scoreboard scb;
    pcie_tl_tag_manager tag_mgr;
    byte unsigned bytes[];
    int unsigned root;
    int unsigned reads_before;
    int unsigned host_before;
    int unsigned successes_before;
    int unsigned failures_before;
    int unsigned kind_before;
    int unsigned requests_before;
    int unsigned completions_before;
    int unsigned matched_before;
    int unsigned timed_out_before;
    int unsigned active_pending_before;
    int unsigned trackers_before;
    int unsigned outstanding_before;
    int unsigned quarantine_before;
    int unsigned late_before;
    int pool_before;
    int pool_expected;

    if (!$cast(dma, env.sys.nodes[0].dev.cmq.dma)) begin
      `uvm_error("PCIE_FAULT", "Function0 DMA port is not rdma_pcie_dma")
      return;
    end
    root = pcie.pcie.host_root[env.sys.nodes[0].func.key.host_id];
    if (root < pcie.pcie.tl_env.ep_agents.size() &&
        pcie.pcie.tl_env.ep_agents[root] != null)
      void'($cast(ep_driver, pcie.pcie.tl_env.ep_agents[root].ep_driver));
    else if (root == 0 && pcie.pcie.tl_env.ep_agent != null)
      void'($cast(ep_driver, pcie.pcie.tl_env.ep_agent.ep_driver));
    if (root >= pcie.pcie.tl_env.scbs.size() ||
        root >= pcie.pcie.tl_env.tag_mgrs.size() || ep_driver == null) begin
      `uvm_error("PCIE_FAULT", $sformatf("Root %0d PCIe verification objects are incomplete", root))
      return;
    end
    scb = pcie.pcie.tl_env.scbs[root];
    tag_mgr = pcie.pcie.tl_env.tag_mgrs[root];
    if (scb == null || tag_mgr == null || !tag_mgr.tag_pool.exists(0)) begin
      `uvm_error("PCIE_FAULT", $sformatf("Root %0d scoreboard/tag pool is unavailable", root))
      return;
    end
    status = pcie.pcie.arm_read_fault(env.sys.nodes[0].func, fault);
    if (!status.ok()) begin
      `uvm_error("PCIE_FAULT", {"could not arm direct fault: ", status.convert2string()})
      return;
    end
    reads_before = pcie.pcie.dma_read_tlps;
    host_before = pcie.pcie.host_reads;
    successes_before = pcie.pcie.dma_read_successes;
    failures_before = pcie.pcie.dma_read_failures;
    kind_before = fault_count(fault);
    requests_before = scb.total_requests;
    completions_before = scb.total_completions;
    matched_before = scb.matched;
    timed_out_before = scb.timed_out;
    active_pending_before = active_pending_count(scb);
    trackers_before = scb.cpl_trackers.size();
    outstanding_before = tag_mgr.get_outstanding_count();
    quarantine_before = ep_driver.timeout_quarantine.num();
    late_before = ep_driver.late_timeout_completions;
    pool_before = tag_mgr.tag_pool[0].size();
    catcher.arm_expectation(fault);
    dma.read(iova, 16, bytes, status);
    catcher.check_consumed(fault.name());
    wait_fault_settlement(scb, fault, requests_before, completions_before, matched_before,
                          timed_out_before, active_pending_before, trackers_before);
    observed = pcie.pcie.last_dma_error(env.sys.nodes[0].func);
    if (status == null || status.code != expected_code || status.ok() || bytes.size() != 0 ||
        status.category != rdma_status::category_for(expected_code) ||
        status.source_engine != RDMA_ENGINE_PCIE ||
        status.function_uid != env.sys.nodes[0].func.global_id ||
        status.hardware_code_valid != hardware_valid ||
        (hardware_valid && status.hardware_code != hardware_code) ||
        status.retryable != retryable || observed != status)
      `uvm_error("PCIE_FAULT", $sformatf("fault %s returned %s bytes=%0d",
                 fault.name(), status == null ? "null" : status.convert2string(), bytes.size()))
    if (pcie.pcie.dma_read_tlps != reads_before + 1 ||
        pcie.pcie.host_reads != host_before + 1 ||
        pcie.pcie.dma_read_successes != successes_before ||
        pcie.pcie.dma_read_failures != failures_before + 1 ||
        fault_count(fault) != kind_before + 1)
      `uvm_error("PCIE_FAULT", $sformatf(
        "fault %s transaction delta sent=%0d host=%0d success=%0d failed=%0d kind=%0d",
        fault.name(),
        pcie.pcie.dma_read_tlps - reads_before, pcie.pcie.host_reads - host_before,
        pcie.pcie.dma_read_successes - successes_before,
        pcie.pcie.dma_read_failures - failures_before, fault_count(fault) - kind_before))
    pool_expected = pool_before - (fault == RDMA_PCIE_FAULT_TIMEOUT ? 1 : 0);
    if (tag_mgr.get_outstanding_count() != outstanding_before ||
        tag_mgr.tag_pool[0].size() != pool_expected || !tag_pool_unique(tag_mgr, 0) ||
        ep_driver.timeout_quarantine.num() !=
          quarantine_before + (fault == RDMA_PCIE_FAULT_TIMEOUT ? 1 : 0) ||
        ep_driver.late_timeout_completions != late_before)
      `uvm_error("PCIE_FAULT", $sformatf(
        {"fault %s tag settlement outstanding=%0d/%0d pool=%0d/%0d ",
         "quarantine=%0d/%0d late=%0d/%0d"},
        fault.name(), tag_mgr.get_outstanding_count(), outstanding_before,
        tag_mgr.tag_pool[0].size(), pool_expected, ep_driver.timeout_quarantine.num(),
        quarantine_before + (fault == RDMA_PCIE_FAULT_TIMEOUT ? 1 : 0),
        ep_driver.late_timeout_completions, late_before))
  endtask

  // 功能：等待当前单条 fault 请求在外部 PCIe scoreboard 中达到唯一合法终态。
  // 输入/输出及副作用：scb/fault 与各 before 计数为只读；最多等待 1us，不修改 scoreboard。
  // 失败/边界：UR/CA 必须增加一条 completion/matched，timeout 必须只增加 timed_out；请求、未完成
  //   pending 或 tracker 未在预算内守恒时报告 UVM_ERROR。
  protected task wait_fault_settlement(pcie_tl_scoreboard scb, rdma_pcie_fault_e fault,
                                       int unsigned requests_before,
                                       int unsigned completions_before,
                                       int unsigned matched_before,
                                       int unsigned timed_out_before,
                                       int unsigned active_pending_before,
                                       int unsigned trackers_before);
    bit settled;

    for (int unsigned n = 0; n < 1000; n++) begin
      settled = scb.total_requests == requests_before + 1 &&
                active_pending_count(scb) == active_pending_before &&
                scb.cpl_trackers.size() == trackers_before;
      if (fault == RDMA_PCIE_FAULT_TIMEOUT)
        settled &= scb.total_completions == completions_before &&
                   scb.matched == matched_before &&
                   scb.timed_out == timed_out_before + 1;
      else
        settled &= scb.total_completions == completions_before + 1 &&
                   scb.matched == matched_before + 1 &&
                   scb.timed_out == timed_out_before;
      if (settled)
        return;
      #1ns;
    end
    `uvm_error("PCIE_FAULT", $sformatf(
      {"fault %s scoreboard did not settle: request=%0d/%0d completion=%0d/%0d ",
      "matched=%0d/%0d timed_out=%0d/%0d active_pending=%0d/%0d tracker=%0d/%0d"},
      fault.name(), scb.total_requests, requests_before + 1, scb.total_completions,
      completions_before + (fault == RDMA_PCIE_FAULT_TIMEOUT ? 0 : 1), scb.matched,
      matched_before + (fault == RDMA_PCIE_FAULT_TIMEOUT ? 0 : 1), scb.timed_out,
      timed_out_before + (fault == RDMA_PCIE_FAULT_TIMEOUT ? 1 : 0),
      active_pending_count(scb), active_pending_before,
      scb.cpl_trackers.size(), trackers_before))
  endtask

  // 功能：统计 scoreboard 中仍未由 requester fold 完成的 pending request，忽略外部 monitor 竞态留下的
  //   rb_done 历史句柄。
  // 输入/输出及副作用：scb 为只读；返回空句柄或 rb_done=0 的条目数，不删除外部 scoreboard 状态。
  // 失败/边界：scb 为空返回 0；该计数只判断事务是否仍在途，不把已完成历史条目视为泄漏。
  protected function int unsigned active_pending_count(pcie_tl_scoreboard scb);
    int unsigned count;

    count = 0;
    if (scb == null)
      return count;
    foreach (scb.pending_requests[tag])
      if (scb.pending_requests[tag] == null || !scb.pending_requests[tag].rb_done)
        count++;
    return count;
  endfunction

  // 功能：检查指定 tag pool 中每个值只出现一次，直接暴露外部 free_tag 重复 push 的双重释放。
  // 输入/输出及副作用：tag_mgr/pool_id 为只读；返回 1 表示 pool 存在且无重复 tag，不修改队列次序。
  // 失败/边界：tag_mgr 为空或 pool_id 不存在返回 0；不检查其他 pool 或 outstanding 所有权。
  protected function bit tag_pool_unique(pcie_tl_tag_manager tag_mgr, int pool_id);
    bit seen[bit [9:0]];

    if (tag_mgr == null || !tag_mgr.tag_pool.exists(pool_id))
      return 1'b0;
    foreach (tag_mgr.tag_pool[pool_id][i]) begin
      if (seen.exists(tag_mgr.tag_pool[pool_id][i]))
        return 1'b0;
      seen[tag_mgr.tag_pool[pool_id][i]] = 1'b1;
    end
    return 1'b1;
  endfunction

  // 功能：读取指定注入类型的累计结算数，使直接 fault 检查能断言 timeout、UR、CA 各自命中。
  // 输入/输出及副作用：fault 为只读枚举；返回 pcie 系统对应计数，不修改故障规则或事务状态。
  // 失败/边界：NONE 或未知值返回 0；调用方只把本函数用于已成功 arm 的三种 fault。
  protected function int unsigned fault_count(rdma_pcie_fault_e fault);
    case (fault)
      RDMA_PCIE_FAULT_TIMEOUT:
        return pcie.pcie.completion_timeouts;
      RDMA_PCIE_FAULT_UR:
        return pcie.pcie.completion_ur;
      RDMA_PCIE_FAULT_CA:
        return pcie.pcie.completion_ca;
      default:
        return 0;
    endcase
  endfunction

  // 功能：把 UR 注入 Function0 驱动下一条 CMQ SQE fetch，验证 posted doorbell 后的双层可观察结果。
  // 输入/输出及副作用：执行 TQ_FLUSH；适配层记录原始 UR，驱动因 CQE 未产生返回 RDMA_SC_TIMEOUT，
  //   并使 failed_writes 增一。
  // 失败/边界：fault 未消费、驱动错误不是 timeout、MMIO 未结算或 last_mmio_error 丢失 UR 硬件码均报错；
  //   命令故意不恢复 CMQ 游标，本测试不再向该 Function 下发后续控制命令。
  protected task check_driver_fault();
    rdma_bytes_t cqe;
    rdma_status status;
    rdma_status arm_status;
    int unsigned failed_before;
    int unsigned ur_before;

    arm_status = pcie.pcie.arm_read_fault(env.sys.nodes[0].func, RDMA_PCIE_FAULT_UR);
    if (!arm_status.ok()) begin
      `uvm_error("PCIE_FAULT", {"could not arm CMQ UR: ", arm_status.convert2string()})
      return;
    end
    failed_before = pcie.pcie.failed_writes;
    ur_before = pcie.pcie.completion_ur;
    catcher.arm_expectation(RDMA_PCIE_FAULT_UR);
    env.sys.nodes[0].drv.cmq.exec(rdma_drv_cmq::new_sqe(RDMA_OP_TQ_FLUSH), cqe, status);
    catcher.check_consumed("CMQ UR");
    if (status == null || status.code != RDMA_SC_TIMEOUT)
      `uvm_error("PCIE_FAULT", {"CMQ driver did not observe timeout: ",
                 status == null ? "null" : status.convert2string()})
    if (pcie.pcie.failed_writes != failed_before + 1 ||
        pcie.pcie.completion_ur != ur_before + 1 || pcie.pcie.last_mmio_error == null ||
        pcie.pcie.last_mmio_error.code != RDMA_SC_PCIE_COMPLETION ||
        !pcie.pcie.last_mmio_error.hardware_code_valid ||
        pcie.pcie.last_mmio_error.hardware_code != CPL_STATUS_UR)
      `uvm_error("PCIE_FAULT", $sformatf(
        "CMQ UR propagation failed: failed delta=%0d UR delta=%0d last=%s",
        pcie.pcie.failed_writes - failed_before, pcie.pcie.completion_ur - ur_before,
        pcie.pcie.last_mmio_error == null ? "null" :
          pcie.pcie.last_mmio_error.convert2string()))
  endtask
endclass
