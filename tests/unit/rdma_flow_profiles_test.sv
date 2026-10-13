// 目录：单元测试层 tests/unit/rdma_flow_profiles_test.sv。
// 层次：模型配置与快照解析测试。
// 职责：验证 TX/RX 独立 QP 数量、resolver 自动关联、netpacket/QPC 冲突拒绝和冻结快照隔离。
// 依赖：rdma_model_pkg；不启动 dpu、driver 或网络 endpoint。
// 所有权与生命周期：测试拥有本地 profile、snapshot 和 status 对象；resolver 输出仅在本用例内使用。
class rdma_flow_profiles_test extends uvm_test;
  `uvm_component_utils(rdma_flow_profiles_test)

  // 功能：构造不带运行资源的配置解析测试。
  // 输入/输出及副作用：name/parent 建立 UVM 层级；不创建 profile 或 endpoint。
  // 失败/边界：顶层 test 的 parent 可为空；具体输入合法性由 run_phase 中的用例覆盖。
  function new(string name = "rdma_flow_profiles_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：检查状态码并将配置解析失败转换为 UVM 错误。
  // 输入/输出及副作用：tag/status/expected 为输入；不修改 resolver 输出。
  // 失败/边界：status 为空或 code 不匹配均报告错误，调用者仍可继续执行其他负向场景。
  function void expect_code(string tag, rdma_status status, rdma_status_code_e expected);
    if (status == null || status.code != expected)
      `uvm_error(tag, status == null ? "resolver returned null status" :
                 $sformatf("expected %s, got %s: %s", expected.name(), status.code.name(),
                           status.message))
  endfunction

  // 功能：创建一个 TX/RX 数量不同但可配对的最小 flow plan。
  // 输入/输出及副作用：返回由本测试拥有的 mutable plan；不解析、不冻结 profile。
  // 失败/边界：plan 含一个 TX QP、两个 RX QP 和一个 SEND message，足以覆盖独立数量路径；
  //   source_id/reset_epoch 已设置以满足 resolver 发布身份要求。
  function rdma_flow_plan make_plan();
    rdma_flow_plan plan;
    rdma_qp_profile tx_qp;
    rdma_qp_profile rx_qp;
    rdma_message_profile msg;

    plan = rdma_flow_plan::type_id::create("flow_plan");
    plan.source_id = "flow_profiles_test";
    plan.reset_epoch = 1;
    plan.tx_qp_count = 1;
    plan.rx_qp_count = 2;
    tx_qp = rdma_qp_profile::type_id::create("tx_qp");
    tx_qp.index = 0;
    rx_qp = rdma_qp_profile::type_id::create("rx_qp0");
    rx_qp.index = 0;
    plan.tx_qps.push_back(tx_qp);
    plan.rx_qps.push_back(rx_qp);
    rx_qp = rdma_qp_profile::type_id::create("rx_qp1");
    rx_qp.index = 1;
    plan.rx_qps.push_back(rx_qp);
    msg = rdma_message_profile::type_id::create("send_message");
    msg.index = 0;
    msg.qp_index = 0;
    msg.payload = '{8'h01, 8'h02, 8'h03, 8'h04};
    msg.length = 4;
    plan.messages.push_back(msg);
    return plan;
  endfunction

  // 功能：解析最小 plan 并验证自动生成的 QPC/HMC/netpacket 绑定和快照隔离。
  // 输入/输出及副作用：创建 config/link 输出并读取其冻结字段；不触碰外部资源。
  // 失败/边界：TX/RX 数量不相等必须成功；任一快照未冻结、QPN 未自动绑定或修改源 payload 影响快照均报错。
  task test_resolve_independent_qps();
    rdma_flow_plan plan;
    rdma_resolved_config config;
    rdma_dut_link_snapshot link;
    rdma_status status;
    int unsigned old_payload_size;

    plan = make_plan();
    status = rdma_flow_resolver::resolve(plan, config, link);
    expect_code("FLOW_RESOLVE", status, RDMA_SC_OK);
    if (config == null || link == null || config.tx_qps.size() != 1 ||
        config.rx_qps.size() != 2 || config.qpcs.size() != 3 ||
        config.messages.size() != 1 || config.netpackets.size() != 1)
      `uvm_error("FLOW_COUNTS", "resolver did not preserve independent TX/RX counts")
    if (config != null && config.netpackets.size() != 0 &&
        config.netpackets[0].qpn != config.tx_qps[0].local_qpn)
      `uvm_error("FLOW_QPN", "netpacket AUTO QPN was not associated with TX QP")
    old_payload_size = config == null ? 0 : config.messages[0].payload.size();
    plan.messages[0].payload.delete();
    if (config != null && config.messages[0].payload.size() != old_payload_size)
      `uvm_error("FLOW_ISOLATION", "resolved message payload aliases mutable profile")
  endtask

  // 功能：构造 netpacket 固定 QPN 与 QPC 自动值冲突的 plan，确认 resolver 保持 QPC 权威。
  // 输入/输出及副作用：只修改本地 plan 的 netpacket profile；返回 resolver status。
  // 失败/边界：固定非零且不同的 QPN 必须返回 INVALID_ARGUMENT，且不发布半成品 config/link。
  task test_reject_netpacket_qpn_conflict();
    rdma_flow_plan plan;
    rdma_netpacket_profile np;
    rdma_resolved_config config;
    rdma_dut_link_snapshot link;
    rdma_status status;

    plan = make_plan();
    np = rdma_netpacket_profile::type_id::create("conflicting_netpacket");
    np.message_index = 0;
    np.qpn_mode = RDMA_FIELD_FIXED;
    np.qpn = 24'h7fffff;
    plan.netpackets.push_back(np);
    status = rdma_flow_resolver::resolve(plan, config, link);
    expect_code("FLOW_QPN_CONFLICT", status, RDMA_SC_INVALID_ARGUMENT);
    if (config != null || link != null)
      `uvm_error("FLOW_QPN_CONFLICT_OUTPUT", "failed resolve published partial snapshots")
  endtask

  // 功能：运行正向和负向 resolver 场景，并在所有断言完成后释放 objection。
  // 输入/输出及副作用：推动 UVM objection 生命周期；只产生测试报告，不修改全局环境。
  // 失败/边界：任一子 task 的 UVM error 会使测试失败；resolver 返回的非预期状态不会中止后续场景。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    test_resolve_independent_qps();
    test_reject_netpacket_qpn_conflict();
    phase.drop_objection(this);
  endtask
endclass
