// 目录：测试层 unit/rdma_context_model_test.sv。
// 职责：验证 rdma_context_model_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_context_model_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// 功能：构造返回 null 状态的 QPC behavior 校验夹具，覆盖 context model 的
//       第一个可覆写嵌套 validator 边界。
// 输入/输出及副作用：name（输入）；new 只初始化本地 UVM 对象；validate()
//       不修改行为字段而返回 null。
// 失败/边界：该 fixture 仅用于验证 QPC fail-closed 语义；null 结果不得被当作
//       成功，也不得继续生成 QPC wire image。
class rdma_null_context_behavior_status extends rdma_qpc_behavior;
  `uvm_object_utils(rdma_null_context_behavior_status)

  // 功能：创建空状态 QPC behavior fixture，并沿用基类字段默认值。
  // 输入/输出及副作用：name（输入）；new 不接管 QP、CMQ 或 context backing
  //       所有权。
  // 失败/边界：构造成功不代表 behavior 有效；本夹具的 validate() 始终返回 null。
  function new(string name = "rdma_null_context_behavior_status");
    super.new(name);
  endfunction

  // 功能：模拟 behavior validator 丢失 rdma_status，验证 QPC 不解引用空句柄。
  // 输入/输出及副作用：无显式输入；不修改字段，返回 null 状态句柄。
  // 失败/边界：null 是刻意注入的 contract violation；调用方必须转换为确定失败。
  virtual function rdma_status validate();
    return null;
  endfunction
endclass

// 功能：构造返回 null 状态的 QPC address-vector 校验夹具，覆盖 QPC 路由扩展边界。
// 输入/输出及副作用：name（输入）；new 只初始化本地 address-vector 值；validate()
//       不访问外部路由资源而返回 null。
// 失败/边界：该 fixture 不可作为真实 address-vector authority 发布。
class rdma_null_context_address_vector_status extends rdma_address_vector;
  `uvm_object_utils(rdma_null_context_address_vector_status)

  // 功能：创建空状态 address-vector fixture。
  // 输入/输出及副作用：name（输入）；new 不修改外部对象或资源所有权。
  // 失败/边界：构造成功不代表 address-vector 已通过驱动字段约束。
  function new(string name = "rdma_null_context_address_vector_status");
    super.new(name);
  endfunction

  // 功能：模拟 address-vector validator 丢失状态，验证 QPC 将异常归一化。
  // 输入/输出及副作用：无显式输入；不修改向量字段，返回 null。
  // 失败/边界：null 返回值不可被调用方继续调用 ok()。
  virtual function rdma_status validate();
    return null;
  endfunction
endclass

// 功能：构造返回 null 状态的 QPC transport-extension 校验夹具，保持 RC 类型身份。
// 输入/输出及副作用：name（输入）；new 建立 RC extension 默认字段；validate()
//       不修改 transport 参数而返回 null。
// 失败/边界：该 fixture 只覆盖状态契约，不改变任何 RC 位域定义。
class rdma_null_context_transport_status extends rdma_qpc_rc_ext;
  `uvm_object_utils(rdma_null_context_transport_status)

  // 功能：创建空状态 RC transport extension fixture。
  // 输入/输出及副作用：name（输入）；new 不接管 QPC 或 CMQ 生命周期。
  // 失败/边界：构造成功不代表 RC extension 可编码。
  function new(string name = "rdma_null_context_transport_status");
    super.new(name);
  endfunction

  // 功能：模拟 RC transport validator 丢失状态，验证 QPC fail-closed。
  // 输入/输出及副作用：无显式输入；不修改 RC 字段，返回 null 状态句柄。
  // 失败/边界：null 是故障注入结果，不能继续解引用。
  virtual function rdma_status validate();
    return null;
  endfunction
endclass

// 功能：构造返回 null 状态的 page-layout 校验夹具，覆盖 CQC/CEQC/AEQC 嵌套布局边界。
// 输入/输出及副作用：name（输入）；new 沿用 page-layout 默认值；validate()
//       不修改布局而返回 null。
// 失败/边界：该 fixture 不改变 page-table 几何或原始驱动布局。
class rdma_null_context_page_layout_status extends rdma_page_table_layout;
  `uvm_object_utils(rdma_null_context_page_layout_status)

  // 功能：创建空状态 page-layout fixture。
  // 输入/输出及副作用：name（输入）；new 不接管 context backing 所有权。
  // 失败/边界：构造成功不代表布局可发布。
  function new(string name = "rdma_null_context_page_layout_status");
    super.new(name);
  endfunction

  // 功能：模拟 page-layout validator 丢失状态，验证各 EQ context model 不解引用空句柄。
  // 输入/输出及副作用：无显式输入；不修改布局字段，返回 null。
  // 失败/边界：null 返回值必须转换为 INVALID_STATE。
  virtual function rdma_status validate();
    return null;
  endfunction
endclass

// 功能：构造返回 null 状态的 ring-position 校验夹具，覆盖 CQC/CEQC/AEQC 的环游标边界。
// 输入/输出及副作用：name（输入）；new 沿用 ring position 默认值；validate()
//       不修改游标而返回 null。
// 失败/边界：该 fixture 仅验证 status 契约，不改变 PI/CI/wrap 语义。
class rdma_null_context_ring_status extends rdma_ring_position;
  `uvm_object_utils(rdma_null_context_ring_status)

  // 功能：创建空状态 ring-position fixture。
  // 输入/输出及副作用：name（输入）；new 不接管队列环或门铃所有权。
  // 失败/边界：构造成功不代表游标可用于硬件上下文。
  function new(string name = "rdma_null_context_ring_status");
    super.new(name);
  endfunction

  // 功能：模拟 ring-position validator 丢失状态，验证 EQ context fail-closed。
  // 输入/输出及副作用：无显式输入；不修改 index/wrap，返回 null。
  // 失败/边界：null 返回值不得继续调用 ok()。
  virtual function rdma_status validate();
    return null;
  endfunction
endclass

class rdma_context_model_test extends uvm_test;
  `uvm_component_utils(rdma_context_model_test)

  localparam longint unsigned TEST_FUNCTION_UID = 64'h1122_3344_5566_7788;
  localparam int unsigned TEST_GENERATION = 32'd7;

  // 功能：构造 rdma_context_model_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_context_model_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_context_model_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：make_handle 创建独立的 rdma_handle；根据 name、kind、object_id、function_uid、generation 设置字段 handle、handle.kind、handle.function_uid、handle.object_id、handle.generation，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、kind（输入）、object_id（输入）、function_uid（输入）、generation（输入）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：make_handle 的结果直接由 return handle 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function rdma_handle make_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id,
    longint unsigned function_uid = TEST_FUNCTION_UID,
    int unsigned generation = TEST_GENERATION
  );
    rdma_handle handle;

    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.function_uid = function_uid;
    handle.object_id = object_id;
    handle.generation = generation;
    return handle;
  endfunction

  // 功能：在 rdma_context_model_test 中，expect_ok 在测试中执行 expect_ok 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、status（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_ok 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function void expect_ok(string label, rdma_status status);
    if (status == null || !status.ok())
      `uvm_error(label, (status == null) ? "status is null" : status.message)
  endfunction

  // 功能：在 rdma_context_model_test 中，expect_invalid 在测试中执行 expect_invalid 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、status（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_invalid 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function void expect_invalid(string label, rdma_status status);
    if (status == null || status.ok())
      `uvm_error(label, "invalid context topology was accepted")
  endfunction

  // 功能：在 rdma_context_model_test 中，expect_invalid_argument 在测试中执行 expect_invalid_argument 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、status（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_invalid_argument 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function void expect_invalid_argument(string label, rdma_status status);
    if (status == null)
      `uvm_error(label, "invalid context topology returned null status")
    else if (status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error(label,
                 $sformatf("expected INVALID_ARGUMENT, got %s (%s)",
                           status.code.name(), status.convert2string()))
  endfunction

  // 功能：expect_code 比较 context model 返回的精确状态码，覆盖 null-status
  //       归一化和其他边界分支的可观察契约。
  // 输入/输出及副作用：label、status、expected（输入）；函数只产生 UVM
  //       error 报告，不修改模型或资源账本。
  // 失败/边界：status 为空或 code 与 expected 不同都报告错误，并保留实际
  //       status 文本，避免把模拟器异常误判为业务拒绝。
  function void expect_code(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null)
      `uvm_error(label, "context model returned null status")
    else if (status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)", expected.name(),
                           status.code.name(), status.convert2string()))
  endfunction

  // 功能：make_page_layout 创建独立的 rdma_page_table_layout；根据 name 设置字段 layout、layout.mode、sd_base.value、current_base.value、layout.current_valid、next_base.value、layout.next_valid，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_page_layout 读取 name 并使用字段 layout、layout.mode、sd_base.value、current_base.value、layout.current_valid、next_base.value、layout.next_valid；函数返回 rdma_page_table_layout，不取得调用方资源所有权。
  // 失败/边界：make_page_layout 的结果直接由 return layout 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function rdma_page_table_layout make_page_layout(string name);
    rdma_page_table_layout layout;

    layout = rdma_page_table_layout::type_id::create(name);
    layout.mode = RDMA_OBJECT_INDIRECT_4K;
    layout.sd_base.value = 64'h0000_0000_0100_0000;
    layout.current_base.value = 64'h0000_0000_0200_0000;
    layout.current_valid = 1'b1;
    layout.next_base.value = 64'h0000_0000_0300_0000;
    layout.next_valid = 1'b1;
    return layout;
  endfunction

  // 功能：make_ring 创建独立的 rdma_ring_position；根据 name、index、wrap 设置字段 position、position.index、position.wrap，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、index（输入）、wrap（输入）；make_ring 读取 name、index、wrap 并使用字段 position、position.index、position.wrap；函数返回 rdma_ring_position，不取得调用方资源所有权。
  // 失败/边界：make_ring 的结果直接由 return position 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function rdma_ring_position make_ring(
    string name,
    int unsigned index,
    bit wrap
  );
    rdma_ring_position position;

    position = rdma_ring_position::type_id::create(name);
    position.index = index;
    position.wrap = wrap;
    return position;
  endfunction

  // 功能：make_address_vector 创建独立的 rdma_address_vector；根据 name 设置字段 vector、vector.source_address_index、vector.source_vport、vector.destination_vport、vector.destination_port、vector.destination_mac、vector.ipv6、vector.vlan_enable、vector.cfi、vector.lag_enable，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_address_vector 读取 name 并使用字段 vector、vector.source_address_index、vector.source_vport、vector.destination_vport、vector.destination_port、vector.destination_mac、vector.ipv6、vector.vlan_enable；函数返回 rdma_address_vector，不取得调用方资源所有权。
  // 失败/边界：make_address_vector 的结果直接由 return vector 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function rdma_address_vector make_address_vector(string name);
    rdma_address_vector vector;

    vector = rdma_address_vector::type_id::create(name);
    vector.source_address_index = 3;
    vector.source_vport = 4;
    vector.destination_vport = 5;
    vector.destination_port = 1;
    vector.destination_mac = 48'h02_11_22_33_44_55;
    foreach (vector.destination_ip[i])
      vector.destination_ip[i] = byte'(i + 1);
    vector.ipv6 = 1'b1;
    vector.vlan_enable = 1'b1;
    vector.cfi = 1'b0;
    vector.lag_enable = 1'b1;
    vector.tunnel_enable = 1'b0;
    vector.forwarding_enable = 1'b1;
    vector.vlan_id = 12'habc;
    vector.traffic_class = 8'haa;
    vector.flow_label = 20'h54321;
    vector.hop_limit = 8'd64;
    vector.udp_source_port = 16'hc123;
    return vector;
  endfunction

  // 功能：make_mr_page_layout 创建独立的 rdma_mr_page_layout；根据 name 设置字段 layout、layout.pbl_mode、layout.host_page_size、pba0.value、layout.pba1、layout.first_pbl_index、layout.address_mode、layout.odp、layout.invalidate_enable、layout.payload_vf_enable，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_mr_page_layout 读取 name 并使用字段 layout、layout.pbl_mode、layout.host_page_size、pba0.value、layout.pba1、layout.first_pbl_index、layout.address_mode、layout.odp；函数返回 rdma_mr_page_layout，不取得调用方资源所有权。
  // 失败/边界：make_mr_page_layout 的结果直接由 return layout 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function rdma_mr_page_layout make_mr_page_layout(string name);
    rdma_mr_page_layout layout;

    layout = rdma_mr_page_layout::type_id::create(name);
    layout.pbl_mode = RDMA_MR_PBL0;
    layout.host_page_size = RDMA_MR_PAGE_4K;
    layout.pba0.value = 64'h0000_0000_0400_0000;
    layout.pba1 = '0;
    layout.first_pbl_index = '0;
    layout.address_mode = RDMA_MR_ADDRESS_VA_BASED;
    layout.odp = 1'b0;
    layout.invalidate_enable = 1'b1;
    layout.payload_vf_enable = 1'b1;
    layout.payload_vf_id = 9;
    layout.mr_serial = 32'h1234;
    return layout;
  endfunction

  // 功能：make_qpc 创建独立的 rdma_qpc_model；根据 name 设置字段 qpc、qpc.qp_h、qpc.pd_h、qpc.send_cq_h、qpc.recv_cq_h、qpc.srq_h、qpc.transport、qpc.state、qpc.host_id、qpc.vf_id，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_qpc 读取 name 并使用字段 qpc、qpc.qp_h、qpc.pd_h、qpc.send_cq_h、qpc.recv_cq_h、qpc.srq_h、qpc.transport、qpc.state；函数返回 rdma_qpc_model，不取得调用方资源所有权。
  // 失败/边界：make_qpc 的结果直接由 return qpc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function rdma_qpc_model make_qpc(string name);
    rdma_qpc_model qpc;
    rdma_qpc_rc_ext rc_ext;

    qpc = rdma_qpc_model::type_id::create(name);
    qpc.qp_h = make_handle({name, "_qp"}, RDMA_RESOURCE_QP, 32'h101);
    qpc.pd_h = make_handle({name, "_pd"}, RDMA_RESOURCE_PD, 32'h202);
    qpc.send_cq_h = make_handle({name, "_scq"}, RDMA_RESOURCE_CQ,
                                32'h303);
    qpc.recv_cq_h = make_handle({name, "_rcq"}, RDMA_RESOURCE_CQ,
                                32'h304);
    qpc.srq_h = make_handle({name, "_srq"}, RDMA_RESOURCE_SRQ, 32'h405);
    qpc.transport = RDMA_TRANSPORT_RC;
    qpc.state = RDMA_QPS_RTS;
    qpc.host_id = 2;
    qpc.vf_id = 3;
    qpc.stat_index = 4;
    qpc.pkey = 16'hffff;
    qpc.qp_sequence = 8'h5a;
    qpc.access = '{local_write:1'b1, remote_read:1'b1,
                   remote_write:1'b1, memory_window_bind:1'b0,
                   remote_atomic:1'b1};
    qpc.path_mtu_bytes = 1024;
    qpc.sq_depth = 64;
    qpc.rq_depth = 32;
    qpc.sq_backing.value = 64'h0000_0000_1000_0000;
    qpc.rq_backing.value = 64'h0000_0000_1100_0000;
    qpc.context_backing.value = 64'h0000_0000_1200_0000;
    qpc.sq_mode = RDMA_OBJECT_DIRECT_4K;
    qpc.rq_mode = RDMA_OBJECT_INDIRECT_4K;
    qpc.address_vector = make_address_vector({name, "_av"});
    qpc.signature_enable = 1'b1;
    qpc.tx_flow_control = 1'b1;
    qpc.rx_flow_control = 1'b0;
    qpc.behavior.transport_version = 1;
    qpc.behavior.migration_enable = 1'b1;
    qpc.behavior.tx_endian_swap = 1'b1;
    qpc.behavior.rx_endian_swap = 1'b1;
    qpc.behavior.read_after_write_fence = 1'b1;
    qpc.behavior.atomic_after_atomic_fence = 1'b1;
    qpc.behavior.\priority = 5;
    rc_ext = rdma_qpc_rc_ext::type_id::create({name, "_rc_ext"});
    rc_ext.remote_qpn = 24'h654321;
    rc_ext.send_psn = 24'habcdef;
    rc_ext.recv_psn = 24'h123456;
    rc_ext.retry_count = 3;
    rc_ext.rnr_retry_count = 4;
    qpc.transport_ext = rc_ext;
    return qpc;
  endfunction

  // 功能：make_cqc 创建独立的 rdma_cqc_model；根据 name 设置字段 cqc、cqc.cq_h、cqc.ceq_h、cqc.state、cqc.depth、cqc.cqe_size_bytes、cqc.threshold、cqc.page_layout、cqc.producer、cqc.consumer，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_cqc 读取 name 并使用字段 cqc、cqc.cq_h、cqc.ceq_h、cqc.state、cqc.depth、cqc.cqe_size_bytes、cqc.threshold、cqc.page_layout；函数返回 rdma_cqc_model，不取得调用方资源所有权。
  // 失败/边界：make_cqc 的结果直接由 return cqc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function rdma_cqc_model make_cqc(string name);
    rdma_cqc_model cqc;

    cqc = rdma_cqc_model::type_id::create(name);
    cqc.cq_h = make_handle({name, "_cq"}, RDMA_RESOURCE_CQ, 32'h301);
    cqc.ceq_h = make_handle({name, "_ceq"}, RDMA_RESOURCE_CEQ, 32'h701);
    cqc.state = RDMA_CONTEXT_VALID;
    cqc.depth = 64;
    cqc.cqe_size_bytes = 64;
    cqc.threshold = 8;
    cqc.page_layout = make_page_layout({name, "_layout"});
    cqc.producer = make_ring({name, "_producer"}, 9, 1'b0);
    cqc.consumer = make_ring({name, "_consumer"}, 3, 1'b0);
    cqc.urc_enable = 1'b1;
    cqc.load_ci_done = 1'b1;
    cqc.last_arm_sequence = 2'd1;
    cqc.arm_sequence = 2'd2;
    cqc.arm_state = 2'd3;
    cqc.shadow_backing.value = 64'h0000_0000_1300_0000;
    return cqc;
  endfunction

  // 功能：make_mrt 创建独立的 rdma_mrt_model；根据 name 设置字段 mrt、mrt.mr_h、mrt.pd_h、mrt.state、iova.value、mrt.length、mrt.lkey、mrt.rkey、mrt.access、mrt.object_type，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_mrt 读取 name 并使用字段 mrt、mrt.mr_h、mrt.pd_h、mrt.state、iova.value、mrt.length、mrt.lkey、mrt.rkey；函数返回 rdma_mrt_model，不取得调用方资源所有权。
  // 失败/边界：make_mrt 的结果直接由 return mrt 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function rdma_mrt_model make_mrt(string name);
    rdma_mrt_model mrt;

    mrt = rdma_mrt_model::type_id::create(name);
    mrt.mr_h = make_handle({name, "_mr"}, RDMA_RESOURCE_MR, 32'h000123);
    mrt.pd_h = make_handle({name, "_pd"}, RDMA_RESOURCE_PD, 32'h000202);
    mrt.state = RDMA_MR_STATE_VALID;
    mrt.iova.value = 64'h0000_0000_8000_0000;
    mrt.length = 64'h2000;
    mrt.lkey = 32'h0001_235a;
    mrt.rkey = mrt.lkey;
    mrt.access = '{local_write:1'b1, remote_read:1'b1,
                   remote_write:1'b1, memory_window_bind:1'b0,
                   remote_atomic:1'b0};
    mrt.object_type = 2'd1;
    mrt.page_layout = make_mr_page_layout({name, "_layout"});
    return mrt;
  endfunction

  // 功能：make_srqc 创建独立的 rdma_srqc_model；根据 name 设置字段 srqc、srqc.srq_h、srqc.pd_h、srqc.state、srqc.depth、srqc.load_pi_threshold、srqc.limit_threshold、srqc.object_mode、srfq_backing.value、shadow_backing.value，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_srqc 读取 name 并使用字段 srqc、srqc.srq_h、srqc.pd_h、srqc.state、srqc.depth、srqc.load_pi_threshold、srqc.limit_threshold、srqc.object_mode；函数返回 rdma_srqc_model，不取得调用方资源所有权。
  // 失败/边界：make_srqc 的结果直接由 return srqc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function rdma_srqc_model make_srqc(string name);
    rdma_srqc_model srqc;

    srqc = rdma_srqc_model::type_id::create(name);
    srqc.srq_h = make_handle({name, "_srq"}, RDMA_RESOURCE_SRQ, 32'h501);
    srqc.pd_h = make_handle({name, "_pd"}, RDMA_RESOURCE_PD, 32'h202);
    srqc.state = RDMA_CONTEXT_VALID;
    srqc.depth = 32;
    srqc.load_pi_threshold = 4;
    srqc.limit_threshold = 8;
    srqc.object_mode = RDMA_OBJECT_DIRECT_4K;
    srqc.srfq_backing.value = 64'h0000_0000_1400_0000;
    srqc.shadow_backing.value = 64'h0000_0000_1500_0000;
    srqc.producer = make_ring({name, "_producer"}, 5, 1'b0);
    srqc.arm_sequence = 2'd2;
    return srqc;
  endfunction

  // 功能：make_ceqc 创建独立的 rdma_ceqc_model；根据 name 设置字段 ceqc、ceqc.ceq_h、ceqc.state、ceqc.depth、ceqc.vector_id、ceqc.page_layout、ceqc.producer、ceqc.consumer，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_ceqc 读取 name 并使用字段 ceqc、ceqc.ceq_h、ceqc.state、ceqc.depth、ceqc.vector_id、ceqc.page_layout、ceqc.producer、ceqc.consumer；函数返回 rdma_ceqc_model，不取得调用方资源所有权。
  // 失败/边界：make_ceqc 的结果直接由 return ceqc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function rdma_ceqc_model make_ceqc(string name);
    rdma_ceqc_model ceqc;

    ceqc = rdma_ceqc_model::type_id::create(name);
    ceqc.ceq_h = make_handle({name, "_ceq"}, RDMA_RESOURCE_CEQ, 32'h701);
    ceqc.state = RDMA_CONTEXT_VALID;
    ceqc.depth = 32;
    ceqc.vector_id = 11;
    ceqc.page_layout = make_page_layout({name, "_layout"});
    ceqc.producer = make_ring({name, "_producer"}, 7, 1'b0);
    ceqc.consumer = make_ring({name, "_consumer"}, 2, 1'b0);
    return ceqc;
  endfunction

  // 功能：make_aeqc 创建独立的 rdma_aeqc_model；根据 name 设置字段 aeqc、aeqc.aeq_h、aeqc.state、aeqc.depth、aeqc.vector_id、aeqc.page_layout、aeqc.producer、aeqc.consumer，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_aeqc 读取 name 并使用字段 aeqc、aeqc.aeq_h、aeqc.state、aeqc.depth、aeqc.vector_id、aeqc.page_layout、aeqc.producer、aeqc.consumer；函数返回 rdma_aeqc_model，不取得调用方资源所有权。
  // 失败/边界：make_aeqc 的结果直接由 return aeqc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function rdma_aeqc_model make_aeqc(string name);
    rdma_aeqc_model aeqc;

    aeqc = rdma_aeqc_model::type_id::create(name);
    aeqc.aeq_h = make_handle({name, "_aeq"}, RDMA_RESOURCE_AEQ, 32'h801);
    aeqc.state = RDMA_CONTEXT_VALID;
    aeqc.depth = 32;
    aeqc.vector_id = 12;
    aeqc.page_layout = make_page_layout({name, "_layout"});
    aeqc.producer = make_ring({name, "_producer"}, 8, 1'b0);
    aeqc.consumer = make_ring({name, "_consumer"}, 1, 1'b0);
    return aeqc;
  endfunction

  // 功能：在 rdma_context_model_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    rdma_rdma_access_t access;
    rdma_dma_permission_t dma_permission;
    uvm_object cloned_object;
    rdma_ring_position ring;
    rdma_ring_position ring_clone;
    rdma_page_table_layout page_layout;
    rdma_page_table_layout page_layout_clone;
    rdma_address_vector address_vector;
    rdma_address_vector address_vector_clone;
    rdma_mr_page_layout mr_page_layout;
    rdma_mr_page_layout mr_page_layout_clone;
    rdma_urc_queue_config urc_queues;
    rdma_urc_queue_config urc_queues_clone;
    rdma_qpc_behavior behavior;
    rdma_qpc_behavior behavior_clone;
    rdma_qpc_model qpc;
    rdma_qpc_model qpc_clone;
    rdma_cqc_model cqc;
    rdma_cqc_model cqc_clone;
    rdma_mrt_model mrt;
    rdma_mrt_model mrt_clone;
    rdma_srqc_model srqc;
    rdma_srqc_model srqc_clone;
    rdma_ceqc_model ceqc;
    rdma_ceqc_model ceqc_clone;
    rdma_aeqc_model aeqc;
    rdma_aeqc_model aeqc_clone;
    rdma_qpc_urc_ext urc_ext;
    rdma_qpc_urc_ext urc_ext_clone;
    rdma_qpc_behavior saved_qpc_behavior;
    rdma_address_vector saved_qpc_address_vector;
    rdma_qpc_transport_ext saved_qpc_transport_ext;
    rdma_null_context_behavior_status null_qpc_behavior;
    rdma_null_context_address_vector_status null_qpc_address_vector;
    rdma_null_context_transport_status null_qpc_transport;
    rdma_page_table_layout saved_page_layout;
    rdma_ring_position saved_ring_position;
    rdma_null_context_page_layout_status null_page_layout;
    rdma_null_context_ring_status null_ring_position;
    rdma_qp qp;
    rdma_srq srq;
    rdma_status status;

    phase.raise_objection(this);

    access = '{local_write:1, remote_read:1, remote_write:1,
               memory_window_bind:0, remote_atomic:1};
    dma_permission = '{device_read:1, device_write:0, atomic:0};
    if (!access.remote_write || dma_permission.device_write)
      `uvm_error("ACCESS_TYPES",
                 "RDMA rights leaked into PCIe DMA permission")

    behavior = rdma_qpc_behavior::type_id::create("behavior");
    if (behavior.transport_version != 0 || behavior.migration_enable != 1'b0 ||
        behavior.tx_endian_swap != 1'b1 ||
        behavior.rx_endian_swap != 1'b1 ||
        behavior.read_after_write_fence != 1'b1 ||
        behavior.atomic_after_atomic_fence != 1'b1 ||
        behavior.\priority != 0)
      `uvm_error("QPC_BEHAVIOR_DEFAULTS",
                 "QPC behavior construction defaults are incorrect")
    expect_ok("QPC_BEHAVIOR_VALID", behavior.validate());
    if (behavior.describe() == "")
      `uvm_error("QPC_BEHAVIOR_DESCRIBE", "QPC behavior description is empty")
    cloned_object = behavior.clone();
    if (!$cast(behavior_clone, cloned_object))
      `uvm_error("QPC_BEHAVIOR_CLONE",
                 "QPC behavior clone lost dynamic type")
    else begin
      behavior_clone.transport_version = 3;
      behavior_clone.\priority = 7;
      if (behavior.transport_version != 0 || behavior.\priority != 0)
        `uvm_error("QPC_BEHAVIOR_CLONE",
                   "QPC behavior clone mutation reached source")
      expect_ok("QPC_BEHAVIOR_CLONE_VALID", behavior_clone.validate());
      behavior_clone.transport_version = 4;
      expect_invalid("QPC_BEHAVIOR_TVER_RANGE", behavior_clone.validate());
      behavior_clone.transport_version = 3;
      behavior_clone.\priority = 8;
      expect_invalid("QPC_BEHAVIOR_PRIORITY_RANGE", behavior_clone.validate());
      behavior_clone.\priority = 7;
    end

    ring = make_ring("ring", 7, 1'b1);
    expect_ok("RING_VALID", ring.validate());
    cloned_object = ring.clone();
    if (!$cast(ring_clone, cloned_object))
      `uvm_error("RING_CLONE", "ring clone lost dynamic type")
    else begin
      ring_clone.index = 8;
      if (ring.index != 7 || ring_clone.describe() == "")
        `uvm_error("RING_CLONE", "ring copy did not preserve value semantics")
    end

    page_layout = make_page_layout("page_layout");
    expect_ok("PAGE_LAYOUT_VALID", page_layout.validate());
    cloned_object = page_layout.clone();
    if (!$cast(page_layout_clone, cloned_object))
      `uvm_error("PAGE_LAYOUT_CLONE", "page layout clone lost dynamic type")
    else begin
      page_layout_clone.current_base.value += 64'h1000;
      if (page_layout.current_base.value != 64'h0000_0000_0200_0000 ||
          page_layout_clone.describe() == "")
        `uvm_error("PAGE_LAYOUT_CLONE", "page layout clone aliases source")
    end

    address_vector = make_address_vector("address_vector");
    expect_ok("ADDRESS_VECTOR_VALID", address_vector.validate());
    cloned_object = address_vector.clone();
    if (!$cast(address_vector_clone, cloned_object))
      `uvm_error("ADDRESS_VECTOR_CLONE", "address vector clone lost type")
    else begin
      address_vector_clone.destination_ip[0] = 8'hff;
      address_vector_clone.vlan_id++;
      if (address_vector.destination_ip[0] != 8'h01 ||
          address_vector.vlan_id != 12'habc ||
          address_vector_clone.describe() == "")
        `uvm_error("ADDRESS_VECTOR_CLONE", "address vector clone aliases source")
    end

    mr_page_layout = make_mr_page_layout("mr_page_layout");
    expect_ok("MR_PAGE_LAYOUT_VALID", mr_page_layout.validate());
    cloned_object = mr_page_layout.clone();
    if (!$cast(mr_page_layout_clone, cloned_object))
      `uvm_error("MR_PAGE_LAYOUT_CLONE", "MR page layout clone lost type")
    else begin
      mr_page_layout_clone.pba0.value += 64'h1000;
      if (mr_page_layout.pba0.value != 64'h0000_0000_0400_0000 ||
          mr_page_layout_clone.describe() == "")
        `uvm_error("MR_PAGE_LAYOUT_CLONE", "MR page layout clone aliases source")
    end

    qpc = make_qpc("qpc");
    expect_ok("QPC_VALID", qpc.validate());

    // RED：QPC 的三个嵌套 virtual validator 若返回 null，context model
    //       必须返回 INVALID_STATE，而不能在 .ok() 处触发 NOA。
    saved_qpc_behavior = qpc.behavior;
    null_qpc_behavior = rdma_null_context_behavior_status::type_id::create(
      "null_qpc_behavior"
    );
    qpc.behavior = null_qpc_behavior;
    expect_code("QPC_NULL_BEHAVIOR_STATUS", qpc.validate(),
                RDMA_SC_INVALID_STATE);
    qpc.behavior = saved_qpc_behavior;

    saved_qpc_address_vector = qpc.address_vector;
    null_qpc_address_vector =
      rdma_null_context_address_vector_status::type_id::create(
        "null_qpc_address_vector"
      );
    qpc.address_vector = null_qpc_address_vector;
    expect_code("QPC_NULL_ADDRESS_VECTOR_STATUS", qpc.validate(),
                RDMA_SC_INVALID_STATE);
    qpc.address_vector = saved_qpc_address_vector;

    saved_qpc_transport_ext = qpc.transport_ext;
    null_qpc_transport = rdma_null_context_transport_status::type_id::create(
      "null_qpc_transport"
    );
    null_qpc_transport.remote_qpn = 24'h654321;
    qpc.transport_ext = null_qpc_transport;
    expect_code("QPC_NULL_TRANSPORT_STATUS", qpc.validate(),
                RDMA_SC_INVALID_STATE);
    qpc.transport_ext = saved_qpc_transport_ext;

    if (qpc.path_mtu_bytes != 1024 ||
        !uvm_is_match("*mtu=1024*", qpc.describe()))
      `uvm_error("QPC_PATH_MTU",
                 "QPC common path MTU is missing from model or description")
    cloned_object = qpc.clone();
    if (!$cast(qpc_clone, cloned_object))
      `uvm_error("QPC_CLONE", "QPC clone lost dynamic type")
    else if (qpc_clone.behavior == null ||
             qpc_clone.address_vector == null ||
             qpc_clone.behavior == qpc.behavior ||
             qpc_clone.address_vector == qpc.address_vector ||
             qpc_clone.transport_ext == qpc.transport_ext ||
             qpc_clone.qp_h == qpc.qp_h ||
             qpc_clone.path_mtu_bytes != 1024)
      `uvm_error("QPC_CLONE", "QPC clone did not deep-copy nested values")
    else begin
      qpc_clone.behavior.\priority = 6;
      qpc_clone.address_vector.destination_mac++;
      qpc_clone.qp_h.object_id++;
      qpc_clone.path_mtu_bytes = 2048;
      if (qpc.behavior.\priority != 5 ||
          qpc.address_vector.destination_mac != 48'h02_11_22_33_44_55 ||
          qpc.qp_h.object_id != 32'h101 ||
          qpc.path_mtu_bytes != 1024)
        `uvm_error("QPC_CLONE", "QPC clone mutation reached source")
    end

    cqc = make_cqc("cqc");
    expect_ok("CQC_VALID", cqc.validate());

    // CQC page layout and ring positions are independently virtual seams; a
    // null status from either must not be mistaken for a valid context.
    saved_page_layout = cqc.page_layout;
    null_page_layout = rdma_null_context_page_layout_status::type_id::create(
      "null_cqc_page_layout"
    );
    cqc.page_layout = null_page_layout;
    expect_code("CQC_NULL_PAGE_LAYOUT_STATUS", cqc.validate(),
                RDMA_SC_INVALID_STATE);
    cqc.page_layout = saved_page_layout;

    saved_ring_position = cqc.producer;
    null_ring_position = rdma_null_context_ring_status::type_id::create(
      "null_cqc_producer"
    );
    cqc.producer = null_ring_position;
    expect_code("CQC_NULL_RING_STATUS", cqc.validate(), RDMA_SC_INVALID_STATE);
    cqc.producer = saved_ring_position;

    cloned_object = cqc.clone();
    if (!$cast(cqc_clone, cloned_object))
      `uvm_error("CQC_CLONE", "CQC clone lost dynamic type")
    else if (cqc_clone.page_layout == cqc.page_layout ||
             cqc_clone.producer == cqc.producer ||
             cqc_clone.consumer == cqc.consumer)
      `uvm_error("CQC_CLONE", "CQC clone aliases nested layout or rings")
    else begin
      cqc_clone.page_layout.current_base.value += 64'h1000;
      cqc_clone.producer.index++;
      if (cqc.page_layout.current_base.value != 64'h0000_0000_0200_0000 ||
          cqc.producer.index != 9)
        `uvm_error("CQC_CLONE", "CQC clone mutation reached source")
    end

    mrt = make_mrt("mrt");
    expect_ok("MRT_VALID", mrt.validate());
    cloned_object = mrt.clone();
    if (!$cast(mrt_clone, cloned_object))
      `uvm_error("MRT_CLONE", "MRT clone lost dynamic type")
    else if (mrt_clone.page_layout == mrt.page_layout)
      `uvm_error("MRT_CLONE", "MRT clone aliases page layout")
    else begin
      mrt_clone.page_layout.pba0.value += 64'h1000;
      if (mrt.page_layout.pba0.value != 64'h0000_0000_0400_0000)
        `uvm_error("MRT_CLONE", "MRT clone mutation reached source")
    end

    srqc = make_srqc("srqc");
    expect_ok("SRQC_VALID", srqc.validate());
    cloned_object = srqc.clone();
    if (!$cast(srqc_clone, cloned_object))
      `uvm_error("SRQC_CLONE", "SRQC clone lost dynamic type")
    else if (srqc_clone.producer == srqc.producer)
      `uvm_error("SRQC_CLONE", "SRQC clone aliases producer position")
    else begin
      srqc_clone.producer.index++;
      if (srqc.producer.index != 5)
        `uvm_error("SRQC_CLONE", "SRQC clone mutation reached source")
    end

    ceqc = make_ceqc("ceqc");
    expect_ok("CEQC_VALID", ceqc.validate());
    saved_page_layout = ceqc.page_layout;
    null_page_layout = rdma_null_context_page_layout_status::type_id::create(
      "null_ceqc_page_layout"
    );
    ceqc.page_layout = null_page_layout;
    expect_code("CEQC_NULL_PAGE_LAYOUT_STATUS", ceqc.validate(),
                RDMA_SC_INVALID_STATE);
    ceqc.page_layout = saved_page_layout;
    cloned_object = ceqc.clone();
    if (!$cast(ceqc_clone, cloned_object))
      `uvm_error("CEQC_CLONE", "CEQC clone lost dynamic type")
    else if (ceqc_clone.page_layout == ceqc.page_layout ||
             ceqc_clone.producer == ceqc.producer ||
             ceqc_clone.consumer == ceqc.consumer)
      `uvm_error("CEQC_CLONE", "CEQC clone aliases nested values")
    else begin
      ceqc_clone.page_layout.next_base.value += 64'h1000;
      if (ceqc.page_layout.next_base.value != 64'h0000_0000_0300_0000)
        `uvm_error("CEQC_CLONE", "CEQC clone mutation reached source")
    end

    aeqc = make_aeqc("aeqc");
    expect_ok("AEQC_VALID", aeqc.validate());
    saved_page_layout = aeqc.page_layout;
    null_page_layout = rdma_null_context_page_layout_status::type_id::create(
      "null_aeqc_page_layout"
    );
    aeqc.page_layout = null_page_layout;
    expect_code("AEQC_NULL_PAGE_LAYOUT_STATUS", aeqc.validate(),
                RDMA_SC_INVALID_STATE);
    aeqc.page_layout = saved_page_layout;
    cloned_object = aeqc.clone();
    if (!$cast(aeqc_clone, cloned_object))
      `uvm_error("AEQC_CLONE", "AEQC clone lost dynamic type")
    else if (aeqc_clone.page_layout == aeqc.page_layout ||
             aeqc_clone.producer == aeqc.producer ||
             aeqc_clone.consumer == aeqc.consumer)
      `uvm_error("AEQC_CLONE", "AEQC clone aliases nested values")
    else begin
      aeqc_clone.consumer.index++;
      if (aeqc.consumer.index != 1)
        `uvm_error("AEQC_CLONE", "AEQC clone mutation reached source")
    end

    qpc.pd_h.kind = RDMA_RESOURCE_CQ;
    expect_invalid("HANDLE_KIND", qpc.validate());
    qpc.pd_h.kind = RDMA_RESOURCE_PD;
    qpc.recv_cq_h.function_uid++;
    expect_invalid("MIXED_FUNCTION_UID", qpc.validate());
    qpc.recv_cq_h.function_uid--;
    qpc.recv_cq_h.generation++;
    expect_invalid("MIXED_GENERATION", qpc.validate());
    qpc.recv_cq_h.generation--;

    qpc.sq_depth = 0;
    expect_invalid("ZERO_DEPTH", qpc.validate());
    qpc.sq_depth = 63;
    expect_invalid("NON_POWER_DEPTH", qpc.validate());
    qpc.sq_depth = 64;
    qpc.sq_backing.value++;
    expect_invalid("QUEUE_ALIGNMENT", qpc.validate());
    qpc.sq_backing.value--;
    qpc.context_backing.value += 64'h100;
    expect_invalid("CONTEXT_ALIGNMENT", qpc.validate());
    qpc.context_backing.value -= 64'h100;
    qpc.path_mtu_bytes = 0;
    status = qpc.validate();
    if (status == null)
      `uvm_error("QPC_ZERO_PATH_MTU", "QPC validation returned null status")
    else if (status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("QPC_ZERO_PATH_MTU",
                 $sformatf("expected INVALID_ARGUMENT, got %s",
                           status.code.name()))
    qpc.path_mtu_bytes = 256;
    expect_ok("QPC_PATH_MTU_256", qpc.validate());
    qpc.path_mtu_bytes = 1024;
    behavior = qpc.behavior;
    qpc.behavior = null;
    expect_invalid("QPC_BEHAVIOR_NULL", qpc.validate());
    qpc.behavior = behavior;
    qpc.behavior.transport_version = 4;
    expect_invalid("QPC_BEHAVIOR_TVER", qpc.validate());
    qpc.behavior.transport_version = 1;
    qpc.behavior.\priority = 8;
    expect_invalid("QPC_BEHAVIOR_PRIORITY", qpc.validate());
    qpc.behavior.\priority = 5;
    qpc.tx_flow_control = 1'b1;
    qpc.rx_flow_control = 1'b0;
    expect_ok("QPC_ASYMMETRIC_FLOW_CONTROL", qpc.validate());
    srqc.srfq_backing.value += 64;
    expect_invalid("SRQC_QUEUE_ALIGNMENT", srqc.validate());
    srqc.srfq_backing.value -= 64;

    urc_queues = rdma_urc_queue_config::type_id::create("urc_queues");
    if (urc_queues.rsq_backing.value != 0 ||
        urc_queues.rdsq_backing.value != 0 ||
        urc_queues.dsq_backing.value != 0 ||
        urc_queues.rsq_depth != 0 || urc_queues.rdsq_depth != 0 ||
        urc_queues.rdsq_fetch_count != 0 ||
        urc_queues.dsq_fetch_count != 0 ||
        urc_queues.rq_sequence_threshold_entries != 0 ||
        urc_queues.sq_completion_threshold_entries != 0)
      `uvm_error("URC_QUEUE_DEFAULTS",
                 "URC queue construction defaults are incorrect")
    expect_invalid_argument("URC_QUEUE_ZERO_DEPTHS", urc_queues.validate());

    urc_queues.rsq_backing.value = 64'h0000_0001_6000_0000;
    urc_queues.rdsq_backing.value = 64'h0000_0001_7000_0000;
    urc_queues.dsq_backing.value = 64'h0000_0001_8000_0000;
    urc_queues.rsq_depth = 64;
    urc_queues.rdsq_depth = 128;
    urc_queues.rdsq_fetch_count = 8;
    urc_queues.dsq_fetch_count = 16;
    urc_queues.rq_sequence_threshold_entries = 16;
    urc_queues.sq_completion_threshold_entries = 32;
    expect_ok("URC_QUEUE_VALID", urc_queues.validate());
    if (!uvm_is_match("*rsq_depth=64*", urc_queues.describe()) ||
        !uvm_is_match("*rdsq_depth=128*", urc_queues.describe()))
      `uvm_error("URC_QUEUE_DESCRIBE",
                 "URC queue description lost queue depths")
    cloned_object = urc_queues.clone();
    if (!$cast(urc_queues_clone, cloned_object))
      `uvm_error("URC_QUEUE_CLONE", "URC queue clone lost dynamic type")
    else begin
      urc_queues_clone.rsq_backing.value += 64'h1000;
      urc_queues_clone.rsq_depth = 256;
      urc_queues_clone.rdsq_fetch_count = 24;
      if (urc_queues.rsq_backing.value != 64'h0000_0001_6000_0000 ||
          urc_queues.rsq_depth != 64 ||
          urc_queues.rdsq_fetch_count != 8)
        `uvm_error("URC_QUEUE_CLONE",
                   "URC queue clone mutation reached source")
    end

    urc_ext = rdma_qpc_urc_ext::type_id::create("urc_ext");
    urc_ext.remote_qpn = 24'h112233;
    urc_ext.rbsn = 24'h010203;
    urc_ext.dbsn = 24'h040506;
    urc_ext.rpsn = 24'h070809;
    urc_ext.dpsn = 24'h0a0b0c;
    urc_ext.queues.copy(urc_queues);
    expect_ok("URC_EXT_VALID", urc_ext.validate());
    urc_ext.remote_qpn = '0;
    expect_invalid_argument("URC_REMOTE_QPN_ZERO", urc_ext.validate());
    urc_ext.remote_qpn = 24'h112233;
    expect_ok("URC_REMOTE_QPN_RESTORED", urc_ext.validate());
    if (!uvm_is_match("*rpsn=460809*", urc_ext.describe()) ||
        !uvm_is_match("*dpsn=658188*", urc_ext.describe()) ||
        !uvm_is_match("*queues=*", urc_ext.describe()))
      `uvm_error("URC_EXT_DESCRIBE",
                 "URC extension description lost canonical fields")
    cloned_object = urc_ext.clone();
    if (!$cast(urc_ext_clone, cloned_object))
      `uvm_error("URC_EXT_CLONE", "URC extension clone lost dynamic type")
    else if (urc_ext_clone.queues == null ||
             urc_ext_clone.queues == urc_ext.queues)
      `uvm_error("URC_EXT_CLONE", "URC extension clone aliased queues")
    else begin
      urc_ext_clone.queues.dsq_backing.value += 64'h1000;
      urc_ext_clone.queues.sq_completion_threshold_entries = 64;
      if (urc_ext.queues.dsq_backing.value !=
            64'h0000_0001_8000_0000 ||
          urc_ext.queues.sq_completion_threshold_entries != 32)
        `uvm_error("URC_EXT_CLONE",
                   "URC extension clone mutation reached source")
    end

    urc_ext.queues = null;
    expect_invalid_argument("URC_QUEUES_NULL", urc_ext.validate());
    cloned_object = urc_ext.clone();
    if (!$cast(urc_ext_clone, cloned_object))
      `uvm_error("URC_EXT_NULL_QUEUES_CLONE",
                 "URC extension clone lost dynamic type")
    else begin
      if (urc_ext_clone.queues != null)
        `uvm_error("URC_EXT_NULL_QUEUES_CLONE",
                   "URC extension clone fabricated a queue configuration")
      expect_invalid_argument("URC_EXT_NULL_QUEUES_CLONE_VALIDATE",
                              urc_ext_clone.validate());
    end
    urc_ext.queues =
      rdma_urc_queue_config::type_id::create("urc_ext_queues_restored");
    urc_ext.queues.copy(urc_queues);
    expect_ok("URC_QUEUES_RESTORED", urc_ext.validate());
    urc_ext.queues.rsq_backing.value++;
    expect_invalid_argument("URC_RSQ_ALIGNMENT", urc_ext.validate());
    urc_ext.queues.rsq_backing.value--;
    urc_ext.queues.rdsq_backing.value++;
    expect_invalid_argument("URC_RDSQ_ALIGNMENT", urc_ext.validate());
    urc_ext.queues.rdsq_backing.value--;
    urc_ext.queues.dsq_backing.value++;
    expect_invalid_argument("URC_DSQ_ALIGNMENT", urc_ext.validate());
    urc_ext.queues.dsq_backing.value--;
    urc_ext.queues.rsq_depth = 48;
    expect_invalid_argument("URC_RSQ_DEPTH", urc_ext.validate());
    urc_ext.queues.rsq_depth = 64;
    urc_ext.queues.rdsq_depth = 0;
    expect_invalid_argument("URC_RDSQ_DEPTH", urc_ext.validate());
    urc_ext.queues.rdsq_depth = 128;
    urc_ext.queues.rq_sequence_threshold_entries = 1;
    expect_invalid_argument("URC_RQ_THRESHOLD_MIN", urc_ext.validate());
    urc_ext.queues.rq_sequence_threshold_entries = 3;
    expect_invalid_argument("URC_RQ_THRESHOLD_POWER_TWO",
                            urc_ext.validate());
    urc_ext.queues.rq_sequence_threshold_entries = 16;
    urc_ext.queues.sq_completion_threshold_entries = 6;
    expect_invalid_argument("URC_SQ_THRESHOLD_POWER_TWO",
                            urc_ext.validate());

    urc_ext.queues.rsq_depth = 1024;
    urc_ext.queues.rdsq_depth = 2048;
    urc_ext.queues.rdsq_fetch_count = 1000;
    urc_ext.queues.dsq_fetch_count = 2000;
    urc_ext.queues.rq_sequence_threshold_entries = 65536;
    urc_ext.queues.sq_completion_threshold_entries = 131072;
    expect_ok("URC_DEVICE_NEUTRAL_WIDTH", urc_ext.validate());

    urc_ext.queues.rsq_depth = 64;
    urc_ext.queues.rdsq_depth = 128;
    urc_ext.queues.rdsq_fetch_count = 8;
    urc_ext.queues.dsq_fetch_count = 16;
    urc_ext.queues.rq_sequence_threshold_entries = qpc.rq_depth;
    urc_ext.queues.sq_completion_threshold_entries = qpc.sq_depth;
    qpc.transport = RDMA_TRANSPORT_URC;
    qpc.transport_ext = urc_ext;
    expect_ok("QPC_URC_THRESHOLDS_AT_DEPTH", qpc.validate());
    urc_ext.queues.rq_sequence_threshold_entries = qpc.rq_depth * 2;
    expect_invalid_argument("QPC_URC_RQ_THRESHOLD_DEPTH", qpc.validate());
    urc_ext.queues.rq_sequence_threshold_entries = qpc.rq_depth;
    urc_ext.queues.sq_completion_threshold_entries = qpc.sq_depth * 2;
    expect_invalid_argument("QPC_URC_SQ_THRESHOLD_DEPTH", qpc.validate());
    urc_ext.queues.sq_completion_threshold_entries = qpc.sq_depth;
    expect_ok("QPC_URC_THRESHOLDS_RESTORED", qpc.validate());

    cqc.shadow_backing.value++;
    expect_invalid("SHADOW_ALIGNMENT", cqc.validate());
    cqc.shadow_backing.value--;
    cqc.producer.index = cqc.depth;
    expect_invalid("RING_INDEX", cqc.validate());
    cqc.producer.index = 9;
    cqc.state = rdma_context_state_e'(2'b11);
    expect_invalid("CONTEXT_STATE", cqc.validate());
    cqc.state = RDMA_CONTEXT_VALID;
    cqc.page_layout.current_base.value++;
    expect_invalid("NESTED_LAYOUT", cqc.validate());
    cqc.page_layout.current_base.value--;

    qpc.qp_h.object_id = 32'h001f_ffff;
    qpc.pd_h.object_id = 32'h0000_ffff;
    qpc.send_cq_h.object_id = 32'h000f_ffff;
    qpc.recv_cq_h.object_id = 32'h000f_ffff;
    qpc.srq_h.object_id = 32'h0000_7fff;
    expect_ok("QPC_ID_WIDTH_MAX", qpc.validate());
    qpc.qp_h.object_id = 32'h0020_0000;
    expect_invalid("QPC_QP_ID_WIDTH", qpc.validate());
    qpc.qp_h.object_id = 32'h001f_ffff;
    qpc.pd_h.object_id = 32'h0001_0000;
    expect_invalid("QPC_PD_ID_WIDTH", qpc.validate());
    qpc.pd_h.object_id = 32'h0000_ffff;
    qpc.send_cq_h.object_id = 32'h0010_0000;
    expect_invalid("QPC_SEND_CQ_ID_WIDTH", qpc.validate());
    qpc.send_cq_h.object_id = 32'h000f_ffff;
    qpc.recv_cq_h.object_id = 32'h0010_0000;
    expect_invalid("QPC_RECV_CQ_ID_WIDTH", qpc.validate());
    qpc.recv_cq_h.object_id = 32'h000f_ffff;
    qpc.srq_h.object_id = 32'h0000_8000;
    expect_invalid("QPC_SRQ_ID_WIDTH", qpc.validate());
    qpc.srq_h = null;
    expect_ok("QPC_OPTIONAL_SRQ", qpc.validate());
    qpc.qp_h.function_uid = '0;
    qpc.qp_h.generation = '0;
    expect_invalid("QPC_MIXED_ZERO_LIFECYCLE", qpc.validate());
    qpc.pd_h.function_uid = '0;
    qpc.pd_h.generation = '0;
    qpc.send_cq_h.function_uid = '0;
    qpc.send_cq_h.generation = '0;
    qpc.recv_cq_h.function_uid = '0;
    qpc.recv_cq_h.generation = '0;
    expect_ok("QPC_DECODE_LIFECYCLE", qpc.validate());

    cqc.cq_h.object_id = 32'h001f_ffff;
    cqc.ceq_h.object_id = 32'h0000_0fff;
    expect_ok("CQC_ID_WIDTH_MAX", cqc.validate());
    cqc.cq_h.object_id = 32'h0020_0000;
    expect_invalid("CQC_CQ_ID_WIDTH", cqc.validate());
    cqc.cq_h.object_id = 32'h001f_ffff;
    cqc.ceq_h.object_id = 32'h0000_1000;
    expect_invalid("CQC_CEQ_ID_WIDTH", cqc.validate());
    cqc.ceq_h = null;
    expect_ok("CQC_OPTIONAL_CEQ", cqc.validate());
    cqc.ceq_h = make_handle("cqc_decode_ceq", RDMA_RESOURCE_CEQ,
                            32'h0000_0fff);

    mrt.mr_h.object_id = 32'h00ff_ffff;
    mrt.pd_h.object_id = 32'h0000_ffff;
    mrt.lkey = 32'hffff_ff5a;
    mrt.rkey = mrt.lkey;
    expect_ok("MRT_ID_WIDTH_MAX", mrt.validate());
    mrt.mr_h.object_id = 32'h0100_0000;
    expect_invalid("MRT_MR_ID_WIDTH", mrt.validate());
    mrt.mr_h.object_id = 32'h00ff_ffff;
    mrt.pd_h.object_id = 32'h0001_0000;
    expect_invalid("MRT_PD_ID_WIDTH", mrt.validate());
    mrt.pd_h.object_id = 32'h0000_ffff;

    srqc.srq_h.object_id = 32'h0000_ffff;
    srqc.pd_h.object_id = 32'h0000_ffff;
    expect_ok("SRQC_ID_WIDTH_MAX", srqc.validate());
    srqc.srq_h.object_id = 32'h0001_0000;
    expect_invalid("SRQC_SRQ_ID_WIDTH", srqc.validate());
    srqc.srq_h.object_id = 32'h0000_ffff;
    srqc.pd_h.object_id = 32'h0001_0000;
    expect_invalid("SRQC_PD_ID_WIDTH", srqc.validate());
    srqc.pd_h.object_id = 32'h0000_ffff;

    ceqc.ceq_h.object_id = 32'h0000_0fff;
    expect_ok("CEQC_ID_WIDTH_MAX", ceqc.validate());
    ceqc.ceq_h.object_id = 32'h0000_1000;
    expect_invalid("CEQC_ID_WIDTH", ceqc.validate());
    ceqc.ceq_h.object_id = 32'h0000_0fff;
    aeqc.aeq_h.object_id = 32'h0000_0fff;
    expect_ok("AEQC_ID_WIDTH_MAX", aeqc.validate());
    aeqc.aeq_h.object_id = 32'h0000_1000;
    expect_invalid("AEQC_ID_WIDTH", aeqc.validate());
    aeqc.aeq_h.object_id = 32'h0000_0fff;

    mr_page_layout.pbl_mode = RDMA_MR_PBL1;
    mr_page_layout.pba1.value = 64'h5000_0000;
    expect_ok("PBL1_VALID", mr_page_layout.validate());
    mr_page_layout.pbl_mode = RDMA_MR_PBL2;
    mr_page_layout.pba0 = '0;
    mr_page_layout.pba1 = '0;
    mr_page_layout.first_pbl_index = 1;
    mr_page_layout.first_pbl_index_valid = 1'b1;
    expect_ok("PBL2_VALID", mr_page_layout.validate());
    mr_page_layout.pbl_mode = rdma_mr_pbl_mode_e'(2'b11);
    expect_invalid("ILLEGAL_MODE", mr_page_layout.validate());
    mr_page_layout.pbl_mode = RDMA_MR_PBL0;
    mr_page_layout.pba0.value = 64'h4000_0000;
    mr_page_layout.first_pbl_index = 0;
    mr_page_layout.pba1.value = 64'h5000_0000;
    expect_invalid("CONTRADICTORY_PBL0", mr_page_layout.validate());
    mr_page_layout.pbl_mode = RDMA_MR_PBL1;
    mr_page_layout.first_pbl_index = 1;
    expect_invalid("CONTRADICTORY_PBL1", mr_page_layout.validate());
    mr_page_layout.pbl_mode = RDMA_MR_PBL2;
    mr_page_layout.pba0.value = 64'h4000_0000;
    mr_page_layout.pba1 = '0;
    mr_page_layout.first_pbl_index = 1;
    mr_page_layout.first_pbl_index_valid = 1'b1;
    expect_invalid("CONTRADICTORY_PBL2", mr_page_layout.validate());

    mrt.length = 0;
    expect_invalid("MRT_ZERO_LENGTH", mrt.validate());
    mrt.length = 64'h0000_4000_0000_0000;
    expect_invalid("MRT_LENGTH_WIDTH", mrt.validate());
    mrt.length = 64'h2000;
    mrt.rkey ^= 32'h1;
    expect_invalid("MRT_KEYS", mrt.validate());
    mrt.rkey = mrt.lkey;
    mrt.mr_h.object_id--;
    expect_invalid("MRT_LKEY_INDEX", mrt.validate());
    mrt.mr_h.object_id++;
    mrt.access = '{local_write:1'b0, remote_read:1'b0,
                   remote_write:1'b1, memory_window_bind:1'b0,
                   remote_atomic:1'b0};
    mrt.rkey = mrt.lkey;
    expect_ok("MRT_REMOTE_WRITE", mrt.validate());
    if (mrt.access.local_write || !mrt.access.remote_write)
      `uvm_error("MRT_ACCESS_MUTATION", "MRT validation normalized access rights")
    mrt.access.remote_read = 1'b0;
    mrt.access.remote_write = 1'b0;
    mrt.access.remote_atomic = 1'b0;
    mrt.access.local_write = 1'b1;
    mrt.rkey = 0;
    expect_ok("MRT_LOCAL_ONLY", mrt.validate());
    if (!mrt.access.local_write || mrt.access.remote_write)
      `uvm_error("MRT_ACCESS_MUTATION", "MRT validation mutated access rights")

    cqc.cq_h.function_uid = '0;
    cqc.cq_h.generation = '0;
    cqc.ceq_h.function_uid = '0;
    cqc.ceq_h.generation = '0;
    expect_ok("DECODE_LIFECYCLE", cqc.validate());

    qp = rdma_qp::type_id::create("qp_runtime_owner");
    qp.sq_depth = 8;
    qp.rq_depth = 4;
    qp.sq_producer_index = 3;
    qp.sq_consumer_index = 1;
    qp.rq_producer_index = 2;
    qp.rq_consumer_index = 0;
    srq = rdma_srq::type_id::create("srq_runtime_owner");
    srq.depth = 8;
    srq.max_sge = 4;
    if (!qp.validate().ok() || !srq.validate().ok())
      `uvm_error("RUNTIME_OWNER", "QP/SRQ resources lost runtime state")

    if (qpc.describe() == "" || cqc.describe() == "" ||
        mrt.describe() == "" || srqc.describe() == "" ||
        ceqc.describe() == "" || aeqc.describe() == "")
      `uvm_error("CONTEXT_DESCRIBE", "context description is empty")

    phase.drop_objection(this);
  endtask
endclass
