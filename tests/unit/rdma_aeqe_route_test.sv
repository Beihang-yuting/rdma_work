// 目录：测试层 tests/unit/。
// 职责：验证 AEQE ecode classifier 的驱动分派类别与 split owner ID 规则。
// 依赖：依赖 rdma_types_pkg 的事件类别函数与 UVM 测试基类，不触碰 codec
//   reserved mask。
// 所有权与生命周期：测试只拥有本地枚举/标量 fixture，不取得资源 manager、
//   queue 或 backing 所有权。

class rdma_aeqe_route_test extends uvm_test;
  `uvm_component_utils(rdma_aeqe_route_test)

  // 功能：构造 AEQE route classifier 测试组件，建立 UVM 层级对象。
  // 输入/输出及副作用：name、parent 为输入；只初始化测试组件，不访问外部资源。
  // 失败/边界：构造不执行 classifier 断言；未进入 run_phase 前不报告测试结果。
  function new(string name = "rdma_aeqe_route_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：断言一个 ecode 映射到驱动 event.c 规定的事件类别。
  // 输入/输出及副作用：label、ecode、expected 为输入；失败时产生 UVM error，
  //   不修改 classifier 或任何资源状态。
  // 失败/边界：未知 ecode 必须按驱动 default 归为 QP；显式 case 映射错误即报告失败。
  function automatic void expect_class(
    string label,
    bit [7:0] ecode,
    rdma_aeqe_event_class_e expected
  );
    rdma_aeqe_event_class_e actual;

    actual = rdma_aeqe_event_class_from_ecode(ecode);
    if (actual != expected)
      `uvm_error(label, $sformatf("ecode 0x%02h expected %s, got %s",
                                  ecode, expected.name(), actual.name()))
  endfunction

  // 功能：run_phase 覆盖 0.1.34 驱动所有显式 AEQE class case，并验证 0xfa/未知
  //   ecode 继续走 QP default，同时核对 split CQN/EQN 的 (high<<6)|low 结果。
  // 输入/输出及副作用：phase 为 UVM phase 输入；只读取 classifier 返回值并产生
  //   断言报告，不创建或修改资源句柄、队列或 backing。
  // 失败/边界：任一显式 ecode、unknown/0xfa default 或 split ID 公式不符时测试失败；
  //   不因 inactive wire overlay 或 reserved mask 而放宽本测试范围。
  virtual task run_phase(uvm_phase phase);
    int unsigned high;
    int unsigned low;
    int unsigned logical_id;

    phase.raise_objection(this);

    expect_class("flush.tx", 8'h07, RDMA_AEQE_EVENT_FLUSH);
    expect_class("flush.qp", 8'h08, RDMA_AEQE_EVENT_FLUSH);
    expect_class("diagnostic.sign", 8'h1f, RDMA_AEQE_EVENT_DIAGNOSTIC);
    expect_class("diagnostic.rx", 8'hba, RDMA_AEQE_EVENT_DIAGNOSTIC);
    expect_class("diagnostic.com_est", 8'hf6, RDMA_AEQE_EVENT_DIAGNOSTIC);
    expect_class("diagnostic.mbus", 8'hff, RDMA_AEQE_EVENT_DIAGNOSTIC);
    expect_class("srq.limit", 8'h78, RDMA_AEQE_EVENT_SRQ);
    expect_class("srq.len", 8'h79, RDMA_AEQE_EVENT_SRQ);
    expect_class("srq.wqe", 8'h7a, RDMA_AEQE_EVENT_SRQ);
    expect_class("srq.state", 8'h7b, RDMA_AEQE_EVENT_SRQ);
    expect_class("cq.occ", 8'hf2, RDMA_AEQE_EVENT_CQ);
    expect_class("cq.invalid", 8'hf3, RDMA_AEQE_EVENT_CQ);
    expect_class("cq.full", 8'hf4, RDMA_AEQE_EVENT_CQ);
    expect_class("cq.pba", 8'hf5, RDMA_AEQE_EVENT_CQ);
    expect_class("eq.ceq.invalid", 8'hf7, RDMA_AEQE_EVENT_EQ);
    expect_class("eq.ceq.full", 8'hf8, RDMA_AEQE_EVENT_EQ);
    expect_class("eq.aeq.full", 8'hfb, RDMA_AEQE_EVENT_EQ);
    expect_class("qp.sqd", 8'h2e, RDMA_AEQE_EVENT_QP);
    expect_class("qp.aeq.invalid.default", 8'hfa, RDMA_AEQE_EVENT_QP);
    expect_class("qp.unknown.default", 8'h09, RDMA_AEQE_EVENT_QP);

    high = 13'h1234;
    low = 6'h2a;
    logical_id = (high << 6) | low;
    if (logical_id != 19'h48d2a)
      `uvm_error("split_owner_id", $sformatf(
        "expected (high<<6)|low = 0x48d2a, got 0x%0h", logical_id))

    phase.drop_objection(this);
  endtask
endclass

class rdma_resource_local_lookup_test extends rdma_resource_manager_test;
  `uvm_component_utils(rdma_resource_local_lookup_test)

  // 功能：构造 resource-manager local lookup 测试组件，复用 manager test 的
  //   active binding fixture 和状态断言辅助函数。
  // 输入/输出及副作用：name、parent 为输入；只初始化 UVM 组件，不取得外部资源。
  // 失败/边界：构造不创建 Function 或资源，所有 manager 状态在 run_phase 内建立。
  function new(string name = "rdma_resource_local_lookup_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：run_phase 创建同一 Function 下的 PD/SRQ，验证按完整 owner/kind/local_id
  //   反查、跨 Function 隔离、超宽 ID 拒绝以及 released/stale 拒绝。
  // 输入/输出及副作用：phase 为 UVM phase 输入；manager 只拥有本地 detached
  //   resource registry，测试结束不释放外部 Host-memory 或 PCIe 资源。
  // 失败/边界：任何错误 kind、owner、generation、local ID 或资源状态被错误接受，
  //   或合法 live resource 未被唯一返回，均报告 UVM error。
  virtual task run_phase(uvm_phase phase);
    rdma_resource_manager manager;
    rdma_function_binding binding_a;
    rdma_function_binding binding_b;
    rdma_pd pd;
    rdma_pd pd_b;
    rdma_srq srq;
    rdma_resource found;
    rdma_status status;
    rdma_function_handle owner_a;
    rdma_function_handle owner_b;
    rdma_function_handle stale_owner;
    int unsigned local_id;

    phase.raise_objection(this);

    manager = new("local_lookup_manager");
    binding_a = make_active_binding("local_lookup_a", 64'h101, 32'h201, 7);
    binding_b = make_active_binding("local_lookup_b", 64'h202, 32'h202, 7);

    status = manager.create_pd(binding_a, pd);
    expect_status("create PD", status, RDMA_SC_OK);
    status = manager.create_srq(binding_a, pd.handle, srq);
    expect_status("create SRQ", status, RDMA_SC_OK);
    status = manager.create_pd(binding_b, pd_b);
    expect_status("create second PD", status, RDMA_SC_OK);
    if (!$cast(owner_a, binding_a.owner_h) || !$cast(owner_b, binding_b.owner_h)) begin
      `uvm_error("lookup owner fixture", "binding owner is not a Function handle")
      phase.drop_objection(this);
      return;
    end
    local_id = srq.local_srq_id;

    status = manager.lookup_local_resource(
      owner_a, RDMA_RESOURCE_SRQ, local_id, found
    );
    expect_status("lookup live SRQ", status, RDMA_SC_OK);
    if (found == null || found.handle == null ||
        found.handle.object_id != srq.handle.object_id)
      `uvm_error("lookup live SRQ", "returned resource identity is incomplete")

    found = null;
    status = manager.lookup_local_resource(
      owner_b, RDMA_RESOURCE_SRQ, local_id, found
    );
    expect_status("lookup cross Function", status, RDMA_SC_INVALID_ARGUMENT);
    if (found != null)
      `uvm_error("lookup cross Function", "cross-Function resource leaked")

    found = null;
    status = manager.lookup_local_resource(
      owner_a, RDMA_RESOURCE_SRQ, 32'h1_0000, found
    );
    expect_status("lookup over-width SRQ", status, RDMA_SC_INVALID_ARGUMENT);

    stale_owner = clone_function_handle("stale owner", owner_a);
    stale_owner.generation++;
    found = null;
    status = manager.lookup_local_resource(
      stale_owner, RDMA_RESOURCE_SRQ, local_id, found
    );
    expect_status("lookup stale generation", status, RDMA_SC_STALE_GENERATION);
    if (found != null)
      `uvm_error("lookup stale generation", "stale resource leaked")

    status = manager.release_reserved(srq.handle);
    expect_status("release SRQ", status, RDMA_SC_OK);
    found = null;
    status = manager.lookup_local_resource(
      owner_a, RDMA_RESOURCE_SRQ, local_id, found
    );
    expect_status("lookup released SRQ", status, RDMA_SC_INVALID_ARGUMENT);
    if (found != null)
      `uvm_error("lookup released SRQ", "released resource leaked")

    phase.drop_objection(this);
  endtask
endclass
