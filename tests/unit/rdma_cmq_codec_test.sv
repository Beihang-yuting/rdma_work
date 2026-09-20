// 目录：测试层 unit/rdma_cmq_codec_test.sv。
// 职责：验证 rdma_cmq_codec_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_cmq_codec_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_hw_cmq_test_overlap_registry
    extends rdma_hw_cmq_body_registry;

  // 功能：构造 rdma_hw_cmq_test_overlap_registry，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_test_overlap_registry 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_test_overlap_registry");
    super.new(name);
  endfunction

  // 功能：在 rdma_hw_cmq_test_overlap_registry 中，force_body 配置测试 fixture 的定向故障或替代依赖，使下一次调用覆盖指定边界路径。
  // 输入/输出及副作用：opcode（输入）、input_kind（输入）、masks（输入）；force_body 读取 opcode、input_kind、masks 并使用输入参数和固定枚举/常量；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：force_body 无返回值，仅执行 函数体中的顺序操作；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void force_body(
    bit [7:0] opcode,
    rdma_image_kind_e input_kind,
    bit [63:0] masks[8]
  );
    set_entry_unchecked(opcode, input_kind, masks);
  endfunction
endclass

typedef enum int unsigned {
  RDMA_CMQ_TEST_ENVELOPE_OUTSIDE_MASK,
  RDMA_CMQ_TEST_ENVELOPE_VALID,
  RDMA_CMQ_TEST_ENVELOPE_VFID_OVERRIDE,
  RDMA_CMQ_TEST_ENVELOPE_VFID,
  RDMA_CMQ_TEST_ENVELOPE_WRAP,
  RDMA_CMQ_TEST_ENVELOPE_INDEX,
  RDMA_CMQ_TEST_ENVELOPE_MUTATE_INPUT
} rdma_hw_cmq_test_envelope_attack_e;

class rdma_hw_cmq_test_bad_envelope_codec
    extends rdma_hw_cmq_envelope_codec;
  rdma_hw_cmq_test_envelope_attack_e attack;

  // 功能：构造 rdma_hw_cmq_test_bad_envelope_codec，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：this.attack=attack。
  // 输入/输出及副作用：name、attack（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_test_bad_envelope_codec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(
    string name = "rdma_hw_cmq_test_bad_envelope_codec",
    rdma_hw_cmq_test_envelope_attack_e attack =
      RDMA_CMQ_TEST_ENVELOPE_OUTSIDE_MASK
  );
    super.new(name);
    this.attack = attack;
  endfunction

  // 功能：在 rdma_hw_cmq_test_bad_envelope_codec 中，encode 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：envelope（输入）、image（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  virtual function rdma_status encode(
    rdma_hw_cmq_envelope envelope,
    output rdma_hw_image image
  );
    rdma_status status;
    status = super.encode(envelope, image);
    if (status.ok() && image != null) begin
      case (attack)
        RDMA_CMQ_TEST_ENVELOPE_OUTSIDE_MASK:
          image.bytes[0] |= 8'h40; // logical qword-0 bit 62
        RDMA_CMQ_TEST_ENVELOPE_VALID:
          image.bytes[0] ^= 8'h80;
        RDMA_CMQ_TEST_ENVELOPE_VFID_OVERRIDE:
          image.bytes[0] ^= 8'h08;
        RDMA_CMQ_TEST_ENVELOPE_VFID:
          image.bytes[1] ^= 8'h01;
        RDMA_CMQ_TEST_ENVELOPE_WRAP:
          image.bytes[2] ^= 8'h20;
        RDMA_CMQ_TEST_ENVELOPE_INDEX:
          image.bytes[2] ^= 8'h01;
        RDMA_CMQ_TEST_ENVELOPE_MUTATE_INPUT:
          envelope.wrap ^= 1'b1;
      endcase
    end
    return status;
  endfunction
endclass

class rdma_hw_cmq_test_forged_body
    extends rdma_hw_cmq_body_image;
  `uvm_object_utils(rdma_hw_cmq_test_forged_body)

  // 功能：构造 rdma_hw_cmq_test_forged_body，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_test_forged_body 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_test_forged_body");
    super.new(name);
  endfunction

  // 功能：copy_and_relabel_attempt 复制 source 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）；copy_and_relabel_attempt 读取 source 并使用输入参数和固定枚举/常量；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：输入为空、类型不匹配或字段组合非法时返回空值/错误；不得发布不完整快照。
  function void copy_and_relabel_attempt(rdma_hw_image source);
    copy(source);
  endfunction
endclass

class rdma_hw_cmq_duplicate_catcher extends uvm_report_catcher;
  bit caught;

  // 功能：构造 rdma_hw_cmq_duplicate_catcher，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：caught=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_duplicate_catcher 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_duplicate_catcher");
    super.new(name);
    caught = 1'b0;
  endfunction

  // 功能：在 rdma_hw_cmq_duplicate_catcher 中，catch 控制 catch 对应的等待、异常或同步边界，按超时/捕获结果返回状态，不吞掉原始错误。
  // 输入/输出及副作用：无显式参数；catch 读取 对象字段：caught 并使用字段 caught；函数返回 action_e，不取得调用方资源所有权。
  // 失败/边界：catch 超时或异常必须返回原始错误证据；不得无限等待或跳过同步边界。
  virtual function action_e catch();
    if (get_severity() == UVM_FATAL &&
        get_id() == "RDMA_CMQ_BODY_DUPLICATE") begin
      caught = 1'b1;
      return CAUGHT;
    end
    return THROW;
  endfunction
endclass

class rdma_cmq_codec_test extends uvm_test;
  `uvm_component_utils(rdma_cmq_codec_test)

  rdma_hw_cmq_body_registry ownership;
  rdma_hw_cmq_light_body_codec light;
  rdma_hw_cmq_request_composer composer;
  rdma_codec_registry context_registry;
  rdma_codec_registry qpc_registry;

  // 功能：构造 rdma_cmq_codec_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_codec_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_codec_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 rdma_cmq_codec_test 中，expect_status 在测试中执行 expect_status 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、status（输入）、expected（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_status 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null)
      `uvm_error(label, "codec returned a null status")
    else if (status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)", expected.name(),
                           status.code.name(), status.convert2string()))
  endfunction

  // 功能：在 rdma_cmq_codec_test 中，expect_ok 在测试中执行 expect_ok 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、status（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_ok 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_ok(string label, rdma_status status);
    expect_status(label, status, RDMA_SC_OK);
  endfunction

  // 功能：make_handle 创建独立的 rdma_handle；根据 name、kind、object_id 设置字段 handle、handle.kind、handle.object_id、handle.function_uid、handle.generation，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、kind（输入）、object_id（输入）；make_handle 读取 name、kind、object_id 并使用字段 handle、handle.kind、handle.object_id、handle.function_uid、handle.generation；函数返回 rdma_handle，不取得调用方资源所有权。
  // 失败/边界：make_handle 的结果直接由 return handle 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_handle make_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle handle;
    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.object_id = object_id;
    handle.function_uid = 64'h1111_2222_3333_4444;
    handle.generation = 7;
    return handle;
  endfunction

  // 功能：make_ring 创建独立的 rdma_ring_position；根据 name、index、wrap 设置字段 ring、ring.index、ring.wrap，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、index（输入）、wrap（输入）；make_ring 读取 name、index、wrap 并使用字段 ring、ring.index、ring.wrap；函数返回 rdma_ring_position，不取得调用方资源所有权。
  // 失败/边界：make_ring 的结果直接由 return ring 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_ring_position make_ring(
    string name,
    int unsigned index,
    bit wrap
  );
    rdma_ring_position ring;
    ring = rdma_ring_position::type_id::create(name);
    ring.index = index;
    ring.wrap = wrap;
    return ring;
  endfunction

  // 功能：make_page_layout 创建独立的 rdma_page_table_layout；根据 name 设置字段 layout、layout.mode、sd_base.value、current_base.value、layout.current_valid、next_base.value、layout.next_valid，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_page_layout 读取 name 并使用字段 layout、layout.mode、sd_base.value、current_base.value、layout.current_valid、next_base.value、layout.next_valid；函数返回 rdma_page_table_layout，不取得调用方资源所有权。
  // 失败/边界：make_page_layout 的结果直接由 return layout 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_page_table_layout make_page_layout(string name);
    rdma_page_table_layout layout;
    layout = rdma_page_table_layout::type_id::create(name);
    layout.mode = RDMA_OBJECT_INDIRECT_4K;
    layout.sd_base.value = 64'h0000_0000_0200_0000;
    layout.current_base.value = 64'h0000_0000_0200_1000;
    layout.current_valid = 1'b1;
    layout.next_base.value = 64'h0000_0000_0200_2000;
    layout.next_valid = 1'b1;
    return layout;
  endfunction

  // 功能：make_cqc 创建独立的 rdma_cqc_model；根据 调用方输入 设置字段 cqc、cqc.cq_h、cqc.ceq_h、cqc.state、cqc.depth、cqc.cqe_size_bytes、cqc.threshold、cqc.page_layout、cqc.producer、cqc.consumer，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：无显式参数；make_cqc 读取局部计算结果，并使用字段 cqc、cqc.cq_h、cqc.ceq_h、cqc.state、cqc.depth、cqc.cqe_size_bytes、cqc.threshold、cqc.page_layout；函数返回 rdma_cqc_model，不取得调用方资源所有权。
  // 失败/边界：make_cqc 的结果直接由 return cqc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_cqc_model make_cqc();
    rdma_cqc_model cqc;
    cqc = rdma_cqc_model::type_id::create("cmq_cqc");
    cqc.cq_h = make_handle("cmq_cq", RDMA_RESOURCE_CQ, 21'h12_345);
    cqc.ceq_h = make_handle("cmq_cq_ceq", RDMA_RESOURCE_CEQ, 12'h234);
    cqc.state = RDMA_CONTEXT_VALID;
    cqc.depth = 1024;
    cqc.cqe_size_bytes = 64;
    cqc.threshold = 5;
    cqc.page_layout = make_page_layout("cmq_cqc_layout");
    cqc.producer = make_ring("cmq_cqc_pi", 17, 1'b1);
    cqc.consumer = make_ring("cmq_cqc_ci", 9, 1'b0);
    cqc.urc_enable = 1'b1;
    cqc.load_ci_done = 1'b1;
    cqc.last_arm_sequence = 2'd2;
    cqc.arm_sequence = 2'd1;
    cqc.arm_state = 2'd2;
    cqc.shadow_backing.value = 64'h0000_0000_0300_0040;
    return cqc;
  endfunction

  // 功能：make_cqc_delete_body 构造携带完整 CQC context 的 typed CQC_DELETE
  //   body，确保测试不会退化为仅填充 CQN 的 legacy fixture。
  // 输入/输出及副作用：name 为输入；返回新建 body 及其独立 CQC context，
  //   不修改其他 fixture 或真实资源账本。
  // 失败/边界：helper 始终绑定 make_cqc() 的有效 context；需要测试缺失 context
  //   时由调用方显式置 null，生产 codec 应拒绝该输入。
  function automatic rdma_hw_cqc_delete_body make_cqc_delete_body(
    string name
  );
    rdma_hw_cqc_delete_body body;

    body = rdma_hw_cqc_delete_body::type_id::create(name);
    body.cqc_context = make_cqc();
    return body;
  endfunction

  // 功能：make_mrt 创建独立的 rdma_mrt_model；根据 name、stag_index、pbl_mode 设置字段 mrt、mrt.mr_h、mrt.pd_h、mrt.state、iova.value、mrt.length、mrt.lkey、mrt.rkey、mrt.access、mrt.object_type，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、stag_index（输入）、RDMA_MR_PBL0（输入）；make_mrt 读取 name、stag_index、pbl_mode 并使用字段 mrt、mrt.mr_h、mrt.pd_h、mrt.state、iova.value、mrt.length、mrt.lkey、mrt.rkey；函数返回 rdma_mrt_model，不取得调用方资源所有权。
  // 失败/边界：make_mrt 先检查 pbl_mode == RDMA_MR_PBL1；pbl_mode == RDMA_MR_PBL2，再返回 mrt；拒绝分支不提交部分状态，也不隐式重试。
  function automatic rdma_mrt_model make_mrt(
    string name,
    int unsigned stag_index,
    rdma_mr_pbl_mode_e pbl_mode = RDMA_MR_PBL0
  );
    rdma_mrt_model mrt;
    mrt = rdma_mrt_model::type_id::create(name);
    mrt.mr_h = make_handle({name, "_mr"}, RDMA_RESOURCE_MR, stag_index);
    mrt.pd_h = make_handle({name, "_pd"}, RDMA_RESOURCE_PD, 16'h3456);
    mrt.state = RDMA_MR_STATE_VALID;
    mrt.iova.value = 64'h0000_1000_2000_3000;
    mrt.length = 64'h12345;
    mrt.lkey = {stag_index[23:0], 8'ha5};
    mrt.rkey = mrt.lkey;
    mrt.access = '{local_write:1'b1, remote_read:1'b1,
                   remote_write:1'b0, memory_window_bind:1'b0,
                   remote_atomic:1'b0};
    mrt.object_type = 2'd0;
    mrt.page_layout.pbl_mode = pbl_mode;
    mrt.page_layout.host_page_size = RDMA_MR_PAGE_4K;
    mrt.page_layout.address_mode = RDMA_MR_ADDRESS_VA_BASED;
    mrt.page_layout.pba0.value = 64'h0000_0000_0400_0000;
    if (pbl_mode == RDMA_MR_PBL1)
      mrt.page_layout.pba1.value = 64'h0000_0000_0400_1000;
    else if (pbl_mode == RDMA_MR_PBL2) begin
      mrt.page_layout.pba0.value = 0;
      mrt.page_layout.first_pbl_index = 28'h123_4567;
      mrt.page_layout.first_pbl_index_valid = 1'b1;
    end
    mrt.page_layout.payload_vf_enable = 1'b1;
    mrt.page_layout.payload_vf_id = 8'h5a;
    mrt.page_layout.mr_serial = 12'h678;
    return mrt;
  endfunction

  // 功能：make_srqc 创建独立的 rdma_srqc_model；根据 调用方输入 设置字段 srqc、srqc.srq_h、srqc.pd_h、srqc.state、srqc.depth、srqc.load_pi_threshold、srqc.limit_threshold、srqc.object_mode、srfq_backing.value、shadow_backing.value，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：无显式参数；make_srqc 读取局部计算结果，并使用字段 srqc、srqc.srq_h、srqc.pd_h、srqc.state、srqc.depth、srqc.load_pi_threshold、srqc.limit_threshold、srqc.object_mode；函数返回 rdma_srqc_model，不取得调用方资源所有权。
  // 失败/边界：make_srqc 的结果直接由 return srqc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_srqc_model make_srqc();
    rdma_srqc_model srqc;
    srqc = rdma_srqc_model::type_id::create("cmq_srqc");
    srqc.srq_h = make_handle("cmq_srq", RDMA_RESOURCE_SRQ, 16'hcdef);
    srqc.pd_h = make_handle("cmq_srq_pd", RDMA_RESOURCE_PD, 16'h3456);
    srqc.state = RDMA_CONTEXT_VALID;
    srqc.depth = 256;
    srqc.load_pi_threshold = 8'h12;
    srqc.limit_threshold = 14'h234;
    srqc.object_mode = RDMA_OBJECT_INDIRECT_4K;
    srqc.srfq_backing.value = 64'h0000_0000_0500_0000;
    srqc.shadow_backing.value = 64'h0000_0000_0500_1000;
    srqc.producer = make_ring("cmq_srqc_pi", 8'h7f, 1'b1);
    srqc.arm_sequence = 2'd3;
    return srqc;
  endfunction

  // 功能：make_ceqc 创建独立的 rdma_ceqc_model；根据 调用方输入 设置字段 ceqc、ceqc.ceq_h、ceqc.state、ceqc.depth、ceqc.vector_id、ceqc.page_layout、sd_base.value、ceqc.producer、ceqc.consumer，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：无显式参数；make_ceqc 读取局部计算结果，并使用字段 ceqc、ceqc.ceq_h、ceqc.state、ceqc.depth、ceqc.vector_id、ceqc.page_layout、sd_base.value、ceqc.producer；函数返回 rdma_ceqc_model，不取得调用方资源所有权。
  // 失败/边界：make_ceqc 的结果直接由 return ceqc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_ceqc_model make_ceqc();
    rdma_ceqc_model ceqc;
    ceqc = rdma_ceqc_model::type_id::create("cmq_ceqc");
    ceqc.ceq_h = make_handle("cmq_ceq", RDMA_RESOURCE_CEQ, 12'habc);
    ceqc.state = RDMA_CONTEXT_VALID;
    ceqc.depth = 1024;
    ceqc.vector_id = 16'h4321;
    ceqc.page_layout = make_page_layout("cmq_ceqc_layout");
    ceqc.page_layout.sd_base.value = 0;
    ceqc.producer = make_ring("cmq_ceqc_pi", 18'h123, 1'b1);
    ceqc.consumer = make_ring("cmq_ceqc_ci", 18'h45, 1'b0);
    return ceqc;
  endfunction

  // 功能：make_aeqc 创建独立的 rdma_aeqc_model；根据 调用方输入 设置字段 aeqc、aeqc.aeq_h、aeqc.state、aeqc.depth、aeqc.vector_id、aeqc.page_layout、sd_base.value、aeqc.producer、aeqc.consumer，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：无显式参数；make_aeqc 读取局部计算结果，并使用字段 aeqc、aeqc.aeq_h、aeqc.state、aeqc.depth、aeqc.vector_id、aeqc.page_layout、sd_base.value、aeqc.producer；函数返回 rdma_aeqc_model，不取得调用方资源所有权。
  // 失败/边界：make_aeqc 的结果直接由 return aeqc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_aeqc_model make_aeqc();
    rdma_aeqc_model aeqc;
    aeqc = rdma_aeqc_model::type_id::create("cmq_aeqc");
    aeqc.aeq_h = make_handle("cmq_aeq", RDMA_RESOURCE_AEQ, 12'h789);
    aeqc.state = RDMA_CONTEXT_VALID;
    aeqc.depth = 1024;
    aeqc.vector_id = 16'h5678;
    aeqc.page_layout = make_page_layout("cmq_aeqc_layout");
    aeqc.page_layout.sd_base.value = 0;
    aeqc.producer = make_ring("cmq_aeqc_pi", 18'h67, 1'b0);
    aeqc.consumer = make_ring("cmq_aeqc_ci", 18'h89, 1'b1);
    return aeqc;
  endfunction

  // 功能：在 rdma_cmq_codec_test 中，context_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：opcode（输入）；context_key 读取 opcode 并使用字段 key.hw_version、key.opcode、key.image_kind、key.object_type、key.variant；函数返回 rdma_codec_key，不取得调用方资源所有权。
// 失败/边界：context_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  function automatic rdma_codec_key context_key(bit [7:0] opcode);
    rdma_codec_key key;
    key.hw_version = "rdma";
    key.opcode = opcode;
    case (opcode)
      RDMA_OP_KEY_ALLOC: begin
        key.image_kind = RDMA_IMAGE_MRT;
        key.object_type = "mrt";
        key.variant = "key_alloc";
      end
      RDMA_OP_MR_REGISTER: begin
        key.image_kind = RDMA_IMAGE_MRT;
        key.object_type = "mrt";
        key.variant = "register";
      end
      RDMA_OP_CQC_CREATE: begin
        key.image_kind = RDMA_IMAGE_CQC;
        key.object_type = "cqc";
        key.variant = "create";
      end
      RDMA_OP_CEQC_CREATE: begin
        key.image_kind = RDMA_IMAGE_CEQC;
        key.object_type = "ceqc";
        key.variant = "create";
      end
      RDMA_OP_AEQC_CREATE: begin
        key.image_kind = RDMA_IMAGE_AEQC;
        key.object_type = "aeqc";
        key.variant = "create";
      end
      RDMA_OP_SRFQC_CREATE: begin
        key.image_kind = RDMA_IMAGE_SRQC;
        key.object_type = "srqc";
        key.variant = "create";
      end
      default: begin
        key.image_kind = RDMA_IMAGE_NONE;
        key.object_type = "invalid";
        key.variant = "invalid";
      end
    endcase
    return key;
  endfunction

  // 功能：在 rdma_cmq_codec_test 中，encode_context 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：label（输入）、opcode（输入）、model（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_context 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  function automatic rdma_hw_image encode_context(
    string label,
    bit [7:0] opcode,
    rdma_hw_model model
  );
    rdma_hw_image image;
    rdma_status status;
    status = composer.build_body(opcode, model, image);
    expect_ok({label, "_ENCODE"}, status);
    return image;
  endfunction

  // 功能：在 rdma_cmq_codec_test 中，image_word 从输入 image/bytes 按固定 offset 提取字段，交付解码所需的值。
  // 输入/输出及副作用：image（输入）、qword_index（输入）；image_word 读取 image、qword_index 并使用字段 word；函数返回 bit [63:0]，不取得调用方资源所有权。
  // 失败/边界：image_word 是只读访问器，返回 word；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  function automatic bit [63:0] image_word(
    rdma_hw_image image,
    int unsigned qword_index
  );
    bit [63:0] word;
    word = '0;
    for (int unsigned i = 0; i < 8; i++)
      word[63 - (i * 8) -: 8] = image.bytes[(qword_index * 8) + i];
    return word;
  endfunction

  // 功能：在 rdma_cmq_codec_test 中，expect_word 在测试中执行 expect_word 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、image（输入）、qword_index（输入）、expected（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT
  //   转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_word 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_word(
    string label,
    rdma_hw_image image,
    int unsigned qword_index,
    bit [63:0] expected
  );
    bit [63:0] actual;
    if (image == null) begin
      `uvm_error(label, "image is null")
      return;
    end
    actual = image_word(image, qword_index);
    if (actual != expected)
      `uvm_error(label,
                 $sformatf("qword %0d expected %016x, got %016x",
                           qword_index, expected, actual))
  endfunction

  // 功能：在 rdma_cmq_codec_test 中，set_image_word 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：image（输入）、qword_index（输入）、word（输入）；set_image_word 先依据 依赖存在性、authority 和 generation 条件 校验 image、qword_index、word；成功时更新本对象配置/状态并保存非拥有引用，返回 void。
  // 失败/边界：set_image_word 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  function automatic void set_image_word(
    rdma_hw_image image,
    int unsigned qword_index,
    bit [63:0] word
  );
    for (int unsigned i = 0; i < 8; i++)
      image.bytes[(qword_index * 8) + i] = word[63 - (i * 8) -: 8];
  endfunction

  // 功能：在 rdma_cmq_codec_test 中，image_field 从输入 image/bytes 按固定 offset 提取字段，交付解码所需的值。
  // 输入/输出及副作用：image（输入）、word_byte_offset（输入）、lsb（输入）、width（输入）；image_field 读取 image、word_byte_offset、lsb、width 并使用字段 mask；函数返回 bit [63:0]，不取得调用方资源所有权。
  // 失败/边界：image_field 的结果直接由 return (image_word(image, word_byte_offset >> 3) >> lsb) & mask 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic bit [63:0] image_field(
    rdma_hw_image image,
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width
  );
    bit [63:0] mask;
    mask = (width == 64) ? '1 : ((64'h1 << width) - 1);
    return (image_word(image, word_byte_offset >> 3) >> lsb) & mask;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_codec_test 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：source（输入）、label（输入）；clone_image 读取 source、label 并使用字段 cloned；函数返回 rdma_hw_image，不取得调用方资源所有权。
  // 失败/边界：clone_image 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  function automatic rdma_hw_image clone_image(
    rdma_hw_image source,
    string label
  );
    uvm_object cloned;
    rdma_hw_image copy;
    cloned = source.clone();
    if (cloned == null || !$cast(copy, cloned)) begin
      `uvm_error(label, "image clone failed")
      return null;
    end
    return copy;
  endfunction

  // 功能：在 rdma_cmq_codec_test 中由 images_equal 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：images_equal 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  function automatic bit images_equal(
    rdma_hw_image lhs,
    rdma_hw_image rhs
  );
    if (lhs == null || rhs == null ||
        lhs.bytes.size() != rhs.bytes.size() ||
        lhs.field_summary.size() != rhs.field_summary.size())
      return 1'b0;
    if (lhs.length != rhs.length || lhs.alignment != rhs.alignment ||
        lhs.endian != rhs.endian || lhs.image_kind != rhs.image_kind ||
        lhs.hardware_version != rhs.hardware_version ||
        lhs.function_generation != rhs.function_generation ||
        lhs.write_target_kind != rhs.write_target_kind ||
        lhs.backing_target.value != rhs.backing_target.value ||
        lhs.hmc_target.value != rhs.hmc_target.value ||
        lhs.bar_target.value != rhs.bar_target.value)
      return 1'b0;
    foreach (lhs.bytes[i])
      if (lhs.bytes[i] != rhs.bytes[i]) return 1'b0;
    foreach (lhs.field_summary[i])
      if (lhs.field_summary[i] != rhs.field_summary[i]) return 1'b0;
    return 1'b1;
  endfunction

  // 功能：在 rdma_cmq_codec_test 中，snapshot_envelope 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：source（输入）、label（输入）；snapshot_envelope 读取 source、label 并使用字段 snapshot、snapshot.valid、snapshot.vfid_override、snapshot.use_vfid、snapshot.wrap、snapshot.wqe_index、snapshot.opcode；函数返回 rdma_hw_cmq_envelope，不取得调用方资源所有权。
  // 失败/边界：snapshot_envelope 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  function automatic rdma_hw_cmq_envelope snapshot_envelope(
    rdma_hw_cmq_envelope source,
    string label
  );
    rdma_hw_cmq_envelope snapshot;
    if (source == null) return null;
    snapshot = rdma_hw_cmq_envelope::type_id::create(label);
    snapshot.valid = source.valid;
    snapshot.vfid_override = source.vfid_override;
    snapshot.use_vfid = source.use_vfid;
    snapshot.wrap = source.wrap;
    snapshot.wqe_index = source.wqe_index;
    snapshot.opcode = source.opcode;
    return snapshot;
  endfunction

  // 功能：在 rdma_cmq_codec_test 中，envelopes_equal 逐字段比较输入快照或镜像，确认其身份、布局和 payload 完全一致后返回布尔结果。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：envelopes_equal 先检查 lhs == null || rhs == null，再返回 lhs == rhs；拒绝分支不提交部分状态，也不隐式重试。
  function automatic bit envelopes_equal(
    rdma_hw_cmq_envelope lhs,
    rdma_hw_cmq_envelope rhs
  );
    if (lhs == null || rhs == null) return lhs == rhs;
    return lhs.valid == rhs.valid &&
           lhs.vfid_override == rhs.vfid_override &&
           lhs.use_vfid == rhs.use_vfid &&
           lhs.wrap == rhs.wrap &&
           lhs.wqe_index == rhs.wqe_index &&
           lhs.opcode == rhs.opcode;
  endfunction

  // 功能：make_envelope 创建独立的 rdma_hw_cmq_envelope；根据 opcode 设置字段 envelope、envelope.valid、envelope.vfid_override、envelope.use_vfid、envelope.wrap、envelope.wqe_index、envelope.opcode，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：opcode（输入）；make_envelope 读取 opcode 并使用字段 envelope、envelope.valid、envelope.vfid_override、envelope.use_vfid、envelope.wrap、envelope.wqe_index、envelope.opcode；函数返回 rdma_hw_cmq_envelope，不取得调用方资源所有权。
  // 失败/边界：make_envelope 的结果直接由 return envelope 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_hw_cmq_envelope make_envelope(
    bit [7:0] opcode
  );
    rdma_hw_cmq_envelope envelope;
    envelope = rdma_hw_cmq_envelope::type_id::create("cmq_envelope");
    envelope.valid = 1'b1;
    envelope.vfid_override = 1'b1;
    envelope.use_vfid = 11'h345;
    envelope.wrap = 1'b1;
    envelope.wqe_index = 5'h1b;
    envelope.opcode = opcode;
    return envelope;
  endfunction

  // 功能：在 rdma_cmq_codec_test 中，qpc_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：variant（输入）；qpc_key 读取 variant 并使用字段 key.hw_version、key.image_kind、key.object_type、key.variant、key.opcode；函数返回 rdma_codec_key，不取得调用方资源所有权。
// 失败/边界：qpc_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  function automatic rdma_codec_key qpc_key(string variant);
    rdma_codec_key key;
    key.hw_version = "rdma";
    key.image_kind = RDMA_IMAGE_QPC;
    key.object_type = "qpc";
    key.variant = variant;
    key.opcode = RDMA_OP_QPC_CREATE;
    return key;
  endfunction

  // 功能：make_signature_qpc 创建独立的 rdma_qpc_model；根据 qpn 设置字段 qpc、qpc.qp_h、qpc.pd_h、qpc.send_cq_h、qpc.recv_cq_h、qpc.srq_h、qpc.transport、qpc.state、qpc.host_id、qpc.vf_id，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：h12345（输入）；make_signature_qpc 读取 qpn 并使用字段 qpc、qpc.qp_h、qpc.pd_h、qpc.send_cq_h、qpc.recv_cq_h、qpc.srq_h、qpc.transport、qpc.state；函数返回 rdma_qpc_model，不取得调用方资源所有权。
  // 失败/边界：make_signature_qpc 的结果直接由 return qpc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_qpc_model make_signature_qpc(
    int unsigned qpn = 21'h12345
  );
    rdma_qpc_model qpc;
    rdma_qpc_rc_ext ext;
    qpc = rdma_qpc_model::type_id::create("cmq_signature_qpc");
    qpc.qp_h = make_handle("cmq_signature_qp", RDMA_RESOURCE_QP, qpn);
    qpc.pd_h = make_handle("cmq_signature_pd", RDMA_RESOURCE_PD, 16'ha55a);
    qpc.send_cq_h = make_handle("cmq_signature_scq", RDMA_RESOURCE_CQ,
                                20'h15555);
    qpc.recv_cq_h = make_handle("cmq_signature_rcq", RDMA_RESOURCE_CQ,
                                20'h0aaaa);
    qpc.srq_h = make_handle("cmq_signature_srq", RDMA_RESOURCE_SRQ,
                            15'h4567);
    qpc.transport = RDMA_TRANSPORT_RC;
    qpc.state = RDMA_QPS_RTS;
    qpc.host_id = 5;
    qpc.vf_id = 12'habc;
    qpc.stat_index = 8'ha5;
    qpc.pkey = 16'hbeef;
    qpc.qp_sequence = 8'hc3;
    qpc.access.local_write = 1'b1;
    qpc.access.remote_read = 1'b1;
    qpc.access.remote_write = 1'b1;
    qpc.access.memory_window_bind = 1'b1;
    qpc.access.remote_atomic = 1'b1;
    qpc.path_mtu_bytes = 8192;
    qpc.sq_depth = 1 << 11;
    qpc.rq_depth = 1 << 10;
    qpc.sq_backing.value = 64'h1234_5678_9abcd000;
    qpc.rq_backing.value = 64'h0fed_cba9_8765_4000;
    qpc.context_backing.value = 64'h123_4567_89ab << 9;
    qpc.sq_mode = RDMA_OBJECT_HUGE_2M;
    qpc.rq_mode = RDMA_OBJECT_INDIRECT_4K;
    qpc.signature_enable = 1'b1;
    qpc.tx_flow_control = 1'b1;
    qpc.rx_flow_control = 1'b1;
    qpc.behavior.transport_version = 1;
    qpc.behavior.migration_enable = 1'b1;
    qpc.behavior.tx_endian_swap = 1'b1;
    qpc.behavior.rx_endian_swap = 1'b1;
    qpc.behavior.read_after_write_fence = 1'b1;
    qpc.behavior.atomic_after_atomic_fence = 1'b1;
    qpc.behavior.\priority  = 0;
    qpc.address_vector.traffic_class = 8'haa;
    qpc.address_vector.destination_mac = 48'h1122_3344_5566;
    qpc.address_vector.vlan_id = 12'habc;
    qpc.address_vector.flow_label = 20'habcde;
    qpc.address_vector.hop_limit = 8'h40;
    qpc.address_vector.udp_source_port = 16'hc123;
    ext = rdma_qpc_rc_ext::type_id::create("cmq_signature_rc_ext");
    ext.remote_qpn = 24'h654321;
    ext.send_psn = 24'habcdef;
    ext.recv_psn = 24'h123456;
    ext.retry_count = 7;
    ext.rnr_retry_count = 7;
    qpc.transport_ext = ext;
    return qpc;
  endfunction

  // 功能：make_signature_ud_qpc 创建独立的 rdma_qpc_model；根据 qpn 设置字段 qpc、qpc.qp_h、qpc.pd_h、qpc.send_cq_h、qpc.recv_cq_h、qpc.transport、qpc.state、qpc.host_id、qpc.vf_id、qpc.stat_index，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：h12345（输入）；make_signature_ud_qpc 读取 qpn 并使用字段 qpc、qpc.qp_h、qpc.pd_h、qpc.send_cq_h、qpc.recv_cq_h、qpc.transport、qpc.state、qpc.host_id；函数返回 rdma_qpc_model，不取得调用方资源所有权。
  // 失败/边界：make_signature_ud_qpc 的结果直接由 return qpc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_qpc_model make_signature_ud_qpc(
    int unsigned qpn = 21'h12345
  );
    rdma_qpc_model qpc;
    rdma_qpc_ud_ext ext;
    byte unsigned ip[16] = '{8'h20,8'h01,8'h0d,8'hb8,
                              8'h00,8'h00,8'h00,8'h00,
                              8'h00,8'h00,8'h00,8'h00,
                              8'h00,8'h00,8'h00,8'h01};

    qpc = rdma_qpc_model::type_id::create("cmq_signature_ud_qpc");
    qpc.qp_h = make_handle("cmq_signature_ud_qp", RDMA_RESOURCE_QP, qpn);
    qpc.pd_h = make_handle("cmq_signature_ud_pd", RDMA_RESOURCE_PD,
                           16'h5aa5);
    qpc.send_cq_h = make_handle("cmq_signature_ud_scq", RDMA_RESOURCE_CQ,
                                20'h13579);
    qpc.recv_cq_h = make_handle("cmq_signature_ud_rcq", RDMA_RESOURCE_CQ,
                                20'h2468a);
    qpc.transport = RDMA_TRANSPORT_UD;
    qpc.state = RDMA_QPS_RTS;
    qpc.host_id = 6;
    qpc.vf_id = 12'h345;
    qpc.stat_index = 8'h5a;
    qpc.pkey = 16'h1234;
    qpc.qp_sequence = 8'h7e;
    qpc.path_mtu_bytes = 4096;
    qpc.sq_depth = 1 << 9;
    qpc.rq_depth = 1 << 8;
    qpc.sq_backing.value = 64'h1111_1222_2233_3000;
    qpc.rq_backing.value = 64'h4444_4555_5566_6000;
    qpc.context_backing.value = 64'h0fed_cba9_876 << 9;
    qpc.sq_mode = RDMA_OBJECT_L3_INDIRECT_4K;
    qpc.rq_mode = RDMA_OBJECT_HUGE_2M;
    qpc.signature_enable = 1'b0;
    qpc.tx_flow_control = 1'b0;
    qpc.rx_flow_control = 1'b0;
    qpc.behavior.transport_version = 1;
    qpc.behavior.migration_enable = 1'b0;
    qpc.behavior.tx_endian_swap = 1'b1;
    qpc.behavior.rx_endian_swap = 1'b1;
    qpc.behavior.read_after_write_fence = 1'b0;
    qpc.behavior.atomic_after_atomic_fence = 1'b0;
    qpc.behavior.\priority  = 5;
    qpc.address_vector.traffic_class = 8'hac;
    qpc.address_vector.vlan_enable = 1'b1;
    qpc.address_vector.ipv6 = 1'b1;
    qpc.address_vector.tunnel_enable = 1'b1;
    qpc.address_vector.lag_enable = 1'b1;
    qpc.address_vector.forwarding_enable = 1'b1;
    qpc.address_vector.destination_vport = 11'h456;
    qpc.address_vector.source_address_index = 12'habc;
    qpc.address_vector.destination_port = 4'hb;
    qpc.address_vector.destination_mac = 48'ha1b2_c3d4_e5f6;
    qpc.address_vector.cfi = 1'b1;
    qpc.address_vector.vlan_id = 12'h789;
    qpc.address_vector.source_vport = 11'h345;
    qpc.address_vector.flow_label = 20'h54321;
    qpc.address_vector.hop_limit = 8'h7f;
    qpc.address_vector.udp_source_port = 16'hbeef;
    foreach (ip[i]) qpc.address_vector.destination_ip[i] = ip[i];
    ext = rdma_qpc_ud_ext::type_id::create("cmq_signature_ud_ext");
    ext.qkey = 32'h89abcdef;
    qpc.transport_ext = ext;
    return qpc;
  endfunction

  // 功能：make_signature_urc_qpc 创建独立的 rdma_qpc_model；根据 qpn 设置字段 qpc、qpc.qp_h、qpc.pd_h、qpc.send_cq_h、qpc.recv_cq_h、qpc.transport、qpc.state、qpc.host_id、qpc.vf_id、qpc.stat_index，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：h12345（输入）；make_signature_urc_qpc 读取 qpn 并使用字段 qpc、qpc.qp_h、qpc.pd_h、qpc.send_cq_h、qpc.recv_cq_h、qpc.transport、qpc.state、qpc.host_id；函数返回 rdma_qpc_model，不取得调用方资源所有权。
  // 失败/边界：make_signature_urc_qpc 的结果直接由 return qpc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_qpc_model make_signature_urc_qpc(
    int unsigned qpn = 21'h12345
  );
    rdma_qpc_model qpc;
    rdma_qpc_urc_ext ext;

    qpc = rdma_qpc_model::type_id::create("cmq_signature_urc_qpc");
    qpc.qp_h = make_handle("cmq_signature_urc_qp", RDMA_RESOURCE_QP, qpn);
    qpc.pd_h = make_handle("cmq_signature_urc_pd", RDMA_RESOURCE_PD,
                           16'hffff);
    qpc.send_cq_h = make_handle("cmq_signature_urc_scq", RDMA_RESOURCE_CQ,
                                20'hfffff);
    qpc.recv_cq_h = make_handle("cmq_signature_urc_rcq", RDMA_RESOURCE_CQ,
                                20'habcde);
    qpc.transport = RDMA_TRANSPORT_URC;
    qpc.state = RDMA_QPS_RTS;
    qpc.host_id = 7;
    qpc.vf_id = 12'h789;
    qpc.stat_index = 8'hff;
    qpc.pkey = 16'habcd;
    qpc.qp_sequence = 8'hfe;
    qpc.access = '0;
    qpc.path_mtu_bytes = 8192;
    qpc.sq_depth = 32768;
    qpc.rq_depth = 16384;
    qpc.sq_backing.value = 64'h4567_89ab_cdef_0000;
    qpc.rq_backing.value = 64'h5678_9abc_def0_1000;
    qpc.context_backing.value = 64'h2468_acf1_35600;
    qpc.sq_mode = RDMA_OBJECT_L3_INDIRECT_4K;
    qpc.rq_mode = RDMA_OBJECT_HUGE_2M;
    qpc.signature_enable = 1'b0;
    qpc.tx_flow_control = 1'b0;
    qpc.rx_flow_control = 1'b0;
    qpc.behavior.transport_version = 1;
    qpc.behavior.migration_enable = 1'b1;
    qpc.behavior.tx_endian_swap = 1'b0;
    qpc.behavior.rx_endian_swap = 1'b0;
    qpc.behavior.read_after_write_fence = 1'b0;
    qpc.behavior.atomic_after_atomic_fence = 1'b0;
    qpc.behavior.\priority  = 0;
    qpc.address_vector.traffic_class = 8'hfe;
    ext = rdma_qpc_urc_ext::type_id::create("cmq_signature_urc_ext");
    ext.remote_qpn = 24'h654321;
    ext.rbsn = 24'habcdef;
    ext.dbsn = 24'h654321;
    ext.rpsn = 24'h56789a;
    ext.dpsn = 24'h456789;
    ext.queues.rsq_backing.value = 64'h1234_5678_9abcd000;
    ext.queues.rdsq_backing.value = 64'h2345_6789_abcde000;
    ext.queues.dsq_backing.value = 64'h3456_789a_bcdef000;
    ext.queues.rsq_depth = 64;
    ext.queues.rdsq_depth = 64;
    ext.queues.rdsq_fetch_count = 8;
    ext.queues.dsq_fetch_count = 8;
    ext.queues.rq_sequence_threshold_entries = 2048;
    ext.queues.sq_completion_threshold_entries = 4096;
    qpc.transport_ext = ext;
    return qpc;
  endfunction

  // 功能：make_qpc_signature_source 创建独立的 rdma_hw_image；根据 qpn、variant 设置字段 status、qpc，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：h12345（输入）、rc（输入）；make_qpc_signature_source 读取 qpn、variant 并使用字段 status、qpc；函数返回 rdma_hw_image，不取得调用方资源所有权。
  // 失败/边界：make_qpc_signature_source 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  function automatic rdma_hw_image make_qpc_signature_source(
    int unsigned qpn = 21'h12345,
    string variant = "rc"
  );
    rdma_codec_base codec;
    rdma_qpc_model qpc;
    rdma_hw_image image;
    rdma_status status;
    status = qpc_registry.lookup(qpc_key(variant), codec);
    expect_ok("QPC_SIGNATURE_SOURCE_LOOKUP", status);
    if (codec == null) begin
      `uvm_error("QPC_SIGNATURE_SOURCE", "QPC codec lookup returned null")
      return null;
    end
    case (variant)
      "rc": qpc = make_signature_qpc(qpn);
      "ud": qpc = make_signature_ud_qpc(qpn);
      "urc": qpc = make_signature_urc_qpc(qpn);
      default: qpc = null;
    endcase
    status = codec.encode(qpc, image);
    expect_ok("QPC_SIGNATURE_SOURCE_ENCODE", status);
    if (image == null)
      `uvm_error("QPC_SIGNATURE_SOURCE", "QPC codec published null")
    return image;
  endfunction

  // 功能：make_qpc_body 创建独立的 rdma_hw_qpc_command_body；根据 name、opcode、modify_mode 设置字段 body、body.qp_h、body.send_cq_h、body.recv_cq_h、qpc_buffer.value、body.next_state、body.full_modify、body.partial_modify、body.wbe_template_count、i，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、opcode（输入）、RDMA_QPC_MODIFY_STATE_ONLY（输入）；make_qpc_body 读取 name、opcode、modify_mode 并使用字段 body、body.qp_h、body.send_cq_h、body.recv_cq_h、qpc_buffer.value、body.next_state、body.full_modify、body.partial_modify；函数返回 rdma_hw_qpc_command_body，不取得调用方资源所有权。
  // 失败/边界：make_qpc_body 先检查 modify_mode == RDMA_QPC_MODIFY_FULL；modify_mode == RDMA_QPC_MODIFY_PARTIAL，再返回 body；拒绝分支不提交部分状态，也不隐式重试。
  function automatic rdma_hw_qpc_command_body make_qpc_body(
    string name,
    bit [7:0] opcode,
    bit [1:0] modify_mode = RDMA_QPC_MODIFY_STATE_ONLY
  );
    rdma_hw_qpc_command_body body;
    body = rdma_hw_qpc_command_body::type_id::create(name);
    body.qp_h = make_handle({name, "_qp"}, RDMA_RESOURCE_QP, 21'h12345);
    case (opcode)
      RDMA_OP_QPC_CREATE: begin
        body.send_cq_h = make_handle({name, "_scq"}, RDMA_RESOURCE_CQ,
                                     21'h15555);
        body.recv_cq_h = make_handle({name, "_rcq"}, RDMA_RESOURCE_CQ,
                                     21'h0aaaa);
        body.qpc_buffer.value = 64'h0000_2468_ace0_0000;
      end
      RDMA_OP_QPC_MODIFY: begin
        body.send_cq_h = make_handle({name, "_scq"}, RDMA_RESOURCE_CQ,
                                     21'h15555);
        body.recv_cq_h = make_handle({name, "_rcq"}, RDMA_RESOURCE_CQ,
                                     21'h0aaaa);
        body.next_state = RDMA_QPS_RTS;
        if (modify_mode == RDMA_QPC_MODIFY_FULL) begin
          body.full_modify = 1'b1;
          body.qpc_buffer.value = 64'h0000_2468_ace0_0000;
        end
        else if (modify_mode == RDMA_QPC_MODIFY_PARTIAL) begin
          body.partial_modify = 1'b1;
          body.wbe_template_count = 2'd1;
          for (int unsigned i = 0; i < 4; i++) begin
            body.modify_start_qword[i] = 6'(i * 7 + 2);
            body.modify_wbe[i] = 8'h81 >> i;
            body.modify_data[i] = 64'h1020_3040_5060_7080 ^ i;
          end
        end
      end
      RDMA_OP_QPC_DELETE: begin
        body.send_cq_h = make_handle({name, "_scq"}, RDMA_RESOURCE_CQ,
                                     21'h15555);
        body.recv_cq_h = make_handle({name, "_rcq"}, RDMA_RESOURCE_CQ,
                                     21'h0aaaa);
      end
      RDMA_OP_QPC_QUERY:
        body.qpc_buffer.value = 64'h0000_2468_ace0_0000;
      default: ;
    endcase
    return body;
  endfunction

  // 功能：make_object_body 创建独立的 rdma_hw_object_id_command_body；根据 name、kind、object_id 设置字段 body、body.object_h，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、kind（输入）、object_id（输入）；make_object_body 读取 name、kind、object_id 并使用字段 body、body.object_h；函数返回 rdma_hw_object_id_command_body，不取得调用方资源所有权。
  // 失败/边界：make_object_body 的结果直接由 return body 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_hw_object_id_command_body make_object_body(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_hw_object_id_command_body body;
    body = rdma_hw_object_id_command_body::type_id::create(name);
    body.object_h = make_handle({name, "_handle"}, kind, object_id);
    return body;
  endfunction

  // 功能：make_occ_vf 创建独立的 rdma_hw_occ_flush_body；根据 name 设置字段 body、body.vf_flush、body.qpc、body.cqc、body.mrt、body.pble、body.sqrqe、body.sgb_irqe、body.eirqe、body.orqe，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_occ_vf 读取 name 并使用字段 body、body.vf_flush、body.qpc、body.cqc、body.mrt、body.pble、body.sqrqe、body.sgb_irqe；函数返回 rdma_hw_occ_flush_body，不取得调用方资源所有权。
  // 失败/边界：make_occ_vf 的结果直接由 return body 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_hw_occ_flush_body make_occ_vf(string name);
    rdma_hw_occ_flush_body body;
    body = rdma_hw_occ_flush_body::type_id::create(name);
    body.vf_flush = 1'b1;
    body.qpc = 1'b1;
    body.cqc = 1'b1;
    body.mrt = 1'b1;
    body.pble = 1'b1;
    body.sqrqe = 1'b1;
    body.sgb_irqe = 1'b1;
    body.eirqe = 1'b1;
    body.orqe = 1'b1;
    body.uaqe = 1'b1;
    return body;
  endfunction

  // 功能：make_occ_serial 创建独立的 rdma_hw_occ_flush_body；根据 name 设置字段 body、body.mr_serial_flush、body.pble、body.mr_serial，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_occ_serial 读取 name 并使用字段 body、body.mr_serial_flush、body.pble、body.mr_serial；函数返回 rdma_hw_occ_flush_body，不取得调用方资源所有权。
  // 失败/边界：make_occ_serial 的结果直接由 return body 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_hw_occ_flush_body make_occ_serial(
    string name
  );
    rdma_hw_occ_flush_body body;
    body = rdma_hw_occ_flush_body::type_id::create(name);
    body.mr_serial_flush = 1'b1;
    body.pble = 1'b1;
    body.mr_serial = 12'habc;
    return body;
  endfunction

  // 功能：make_occ_qpn 创建独立的 rdma_hw_occ_flush_body；根据 name 设置字段 body、body.qpn、body.eirqe、body.orqe、body.uaqe，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_occ_qpn 读取 name 并使用字段 body、body.qpn、body.eirqe、body.orqe、body.uaqe；函数返回 rdma_hw_occ_flush_body，不取得调用方资源所有权。
  // 失败/边界：make_occ_qpn 的结果直接由 return body 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_hw_occ_flush_body make_occ_qpn(string name);
    rdma_hw_occ_flush_body body;
    body = rdma_hw_occ_flush_body::type_id::create(name);
    body.qpn = 21'h12345;
    body.eirqe = 1'b1;
    body.orqe = 1'b1;
    body.uaqe = 1'b1;
    return body;
  endfunction

  // 功能：make_occ_qpn_pd 创建独立的 rdma_hw_occ_flush_body；根据 name 设置字段 body、body.qpn、body.pd、pd_backing.value，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_occ_qpn_pd 读取 name 并使用字段 body、body.qpn、body.pd、pd_backing.value；函数返回 rdma_hw_occ_flush_body，不取得调用方资源所有权。
  // 失败/边界：make_occ_qpn_pd 的结果直接由 return body 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_hw_occ_flush_body make_occ_qpn_pd(
    string name
  );
    rdma_hw_occ_flush_body body;
    body = rdma_hw_occ_flush_body::type_id::create(name);
    body.qpn = 21'h12345;
    body.pd = 1'b1;
    body.pd_backing.value = 64'h0000_0000_0600_0000;
    return body;
  endfunction

  // 功能：make_occ_pd 创建独立的 rdma_hw_occ_flush_body；根据 name 设置字段 body、body.pd、pd_backing.value，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_occ_pd 读取 name 并使用字段 body、body.pd、pd_backing.value；函数返回 rdma_hw_occ_flush_body，不取得调用方资源所有权。
  // 失败/边界：make_occ_pd 的结果直接由 return body 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_hw_occ_flush_body make_occ_pd(string name);
    rdma_hw_occ_flush_body body;
    body = rdma_hw_occ_flush_body::type_id::create(name);
    body.pd = 1'b1;
    body.pd_backing.value = 64'h0000_0000_0600_0000;
    return body;
  endfunction

  // 功能：在 rdma_cmq_codec_test 中，encode_light 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：label（输入）、opcode（输入）、model（输入）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_light 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  function automatic rdma_hw_image encode_light(
    string label,
    bit [7:0] opcode,
    rdma_hw_model model
  );
    rdma_hw_image image;
    rdma_status status;
    status = composer.build_body(opcode, model, image);
    expect_ok({label, "_ENCODE"}, status);
    if (image == null)
      `uvm_error(label, "successful light encode published null")
    return image;
  endfunction

  // 功能：在 rdma_cmq_codec_test 中，expect_light_failure 在测试中执行 expect_light_failure 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、opcode（输入）、model（输入）、expected（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT
  //   转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_light_failure 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_light_failure(
    string label,
    bit [7:0] opcode,
    rdma_hw_model model,
    rdma_status_code_e expected
  );
    rdma_hw_image image;
    rdma_status status;
    image = rdma_hw_image::type_id::create({label, "_sentinel"});
    status = light.encode(opcode, model, image);
    expect_status(label, status, expected);
    if (image != null)
      `uvm_error(label, "failed light encode published an image")
  endfunction

  // 功能：make_occ_completion_image 构造一份带 OCC 查询返回字段的 64B CMQ CQE，
  //   用于验证驱动 cmq.c 对 qword0/qword1/qword3 的三段读取契约。
  // 输入/输出及副作用：opcode、return_index、occ_num、start_index、occ_key 和
  //   buffer_addr 为输入；返回新建 CQE 镜像，不修改调用方对象或 CMQ 账本。
  // 失败/边界：该 fixture 只接受 20 个 OCC/IDX 查询 opcode；调用者若传入其他
  //   opcode 仍会得到原始镜像，实际合法性由 completion codec 负责拒绝。
  function automatic rdma_hw_image make_occ_completion_image(
    bit [7:0] opcode,
    bit [11:0] return_index,
    bit [7:0] occ_num,
    bit [11:0] start_index,
    bit [39:0] occ_key,
    bit [63:0] buffer_addr
  );
    rdma_hw_image image;
    bit [63:0] qword0;

    image = rdma_hw_image::type_id::create("cmq_occ_completion_image");
    repeat (RDMA_CMQE_BYTES) image.bytes.push_back(8'h00);
    image.length = RDMA_CMQE_BYTES;
    image.alignment = RDMA_CMQE_BYTES;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_CMQ_CQE;
    image.hardware_version = RDMA_HW_VERSION;
    image.function_generation = 0;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;

    qword0 = 64'h8000_0000_0000_0000 |
             (64'(opcode) << RDMA_CMQ_OPCODE_LSB) |
             (64'(8'h00) << RDMA_CMQ_CMD_ECODE_LSB) |
             (64'(5'h03) << RDMA_CMQ_WQE_INDEX_LSB) |
             (64'(1'b1) << RDMA_CMQ_WRAP_LSB) |
             (64'(return_index) << RDMA_CMQ_COMPLETION_RETURN_OCC_IDX_LSB) |
             (64'(occ_num) << 16) |
             start_index;
    set_occ_image_word(image, 0, qword0);
    set_occ_image_word(image, 1, occ_key);
    set_occ_image_word(image, 3, buffer_addr);
    return image;
  endfunction

  // 功能：set_occ_image_word 将一个逻辑大端 qword 写入 OCC CQE 镜像，供测试 fixture
  //   精确构造驱动可观察的 raw bytes。
  // 输入/输出及副作用：image、qword_index 和 value 为输入；函数只写 image.bytes
  //   对应的八个字节，不修改 metadata、源值或生产 codec 状态。
  // 失败/边界：image 为空或 qword_index 超过 7 时不写入；越界不会隐式扩展镜像。
  function automatic void set_occ_image_word(
    rdma_hw_image image,
    int unsigned qword_index,
    bit [63:0] value
  );
    if (image == null || qword_index > 7)
      return;
    for (int unsigned i = 0; i < 8; i++)
      image.bytes[(qword_index * 8) + i] = value[63 - (i * 8) -: 8];
  endfunction

  // 功能：make_query_completion_image 构造 CEQC/AEQC、SRFQC 或 IFA query 的
  //   最小真实 CQE，保留驱动在 qword0/qword1 读取的字段。
  // 输入/输出及副作用：opcode、qword0_payload、qword1_payload 为输入；返回
  //   独立的 64-byte 大端 CMQ CQE，不修改调用方对象或 completion codec。
  // 失败/边界：该 helper 只负责构造 raw image；opcode 与 payload 的语义/保留位
  //   仍由 inspect_completion() 校验，未声明的 qword 保持零值。
  function automatic rdma_hw_image make_query_completion_image(
    bit [7:0] opcode,
    bit [63:0] qword0_payload,
    bit [63:0] qword1_payload
  );
    rdma_hw_image image;
    bit [63:0] qword0;

    image = rdma_hw_image::type_id::create("cmq_query_completion_image");
    repeat (RDMA_CMQE_BYTES)
      image.bytes.push_back(8'h00);
    image.length = RDMA_CMQE_BYTES;
    image.alignment = RDMA_CMQE_BYTES;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_CMQ_CQE;
    image.hardware_version = RDMA_HW_VERSION;
    image.function_generation = 0;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;

    qword0 = 64'h8000_0000_0000_0000 |
             (64'(opcode) << RDMA_CMQ_OPCODE_LSB) |
             (64'(5'h03) << RDMA_CMQ_WQE_INDEX_LSB) |
             (64'(1'b1) << RDMA_CMQ_WRAP_LSB) |
             qword0_payload;
    set_occ_image_word(image, 0, qword0);
    set_occ_image_word(image, 1, qword1_payload);
    return image;
  endfunction

  // 功能：check_driver_body_mask_contracts 对照 cmq.h/cmq.c 冻结 CQC_DELETE 与
  //   OCC search 的请求/完成字段所有权，并验证真实 OCC CQE 能被接收。
  // 输入/输出及副作用：无显式输入；读取静态 opcode registry 和 completion codec，
  //   仅产生 UVM 断言，不修改 registry、镜像或运行时资源。
  // 失败/边界：缺失 CQC qword1..7、OCC qword3 buffer 地址、OCC CQE 返回字段或
  //   opcode admission 均报告 UVM_ERROR；测试不会把缺陷降级为 warning。
  function automatic void check_driver_body_mask_contracts();
    rdma_cmq_opcode_descriptor descriptor;
    rdma_hw_cmq_completion_codec completion_codec;
    rdma_hw_image image;
    rdma_hw_cmq_completion completion;
    rdma_status status;
    bit ready;
    bit [7:0] query_opcodes[4] = '{
      RDMA_OP_CEQC_QUERY,
      RDMA_OP_AEQC_QUERY,
      RDMA_OP_SRFQC_QUERY,
      RDMA_OP_IFA_QUERY
    };

    status = rdma_cmq_codec_registry::lookup(RDMA_OP_CQC_DELETE,
                                             descriptor);
    expect_ok("CQC_DELETE_DESCRIPTOR", status);
    if (descriptor != null &&
        (descriptor.request_qword_masks[0] != 64'h0000_0000_001f_ffff ||
         descriptor.request_qword_masks[1] != 64'hff0f_ffff_ffff_ffff ||
         descriptor.request_qword_masks[2] != 64'hffff_ffff_ffff_f8ff ||
         descriptor.request_qword_masks[3] != 64'hffff_ffff_fff8_c701 ||
         descriptor.request_qword_masks[4] != 64'hf000_0000_00ff_ffff ||
         descriptor.request_qword_masks[5] != 64'h0000_0000_0000_0fff ||
         descriptor.request_qword_masks[6] != 64'hffff_ffff_ffff_ffc0 ||
         descriptor.request_qword_masks[7] != 64'h0000_000f_00ff_ffff))
      `uvm_error("CQC_DELETE_DESCRIPTOR",
                 "CQC_DELETE mask does not map qword1..7 to context qword0..6")

    status = rdma_cmq_codec_registry::lookup(RDMA_OP_OCC_QPC, descriptor);
    expect_ok("OCC_QPC_DESCRIPTOR", status);
    if (descriptor != null && descriptor.request_qword_masks[3] == 0)
      `uvm_error("OCC_QPC_DESCRIPTOR",
                 "OCC key search must own qword3 buffer address")

    status = rdma_cmq_codec_registry::lookup(RDMA_OP_IDX_OCC_QPC,
                                             descriptor);
    expect_ok("IDX_OCC_QPC_DESCRIPTOR", status);
    if (descriptor != null && descriptor.request_qword_masks[3] == 0)
      `uvm_error("IDX_OCC_QPC_DESCRIPTOR",
                 "OCC index search must own qword3 buffer address")

    status = rdma_cmq_codec_registry::lookup(RDMA_OP_MW_ALLOC,
                                             descriptor);
    expect_ok("MW_ALLOC_DESCRIPTOR", status);
    if (descriptor != null &&
        descriptor.request_qword_masks[2] !=
          64'he0c1_ffff_ff00_0000)
      `uvm_error("MW_ALLOC_DESCRIPTOR",
                 "MW_ALLOC qword2 ownership does not match cmq.c")

    status = rdma_cmq_codec_registry::lookup(RDMA_OP_MW_DEALLOC,
                                             descriptor);
    expect_ok("MW_DEALLOC_DESCRIPTOR", status);
    if (descriptor != null &&
        descriptor.request_qword_masks[2] !=
          64'hc001_ffff_ff00_0000)
      `uvm_error("MW_DEALLOC_DESCRIPTOR",
                 "MW_DEALLOC qword2 overclaims alloc-only fields")

    status = rdma_cmq_codec_registry::lookup(RDMA_OP_CQC_MODIFY,
                                             descriptor);
    expect_ok("CQC_MODIFY_DESCRIPTOR", status);
    if (descriptor != null &&
        descriptor.request_qword_masks[0] !=
          64'h7000_0000_ffdf_ffff)
      `uvm_error("CQC_MODIFY_DESCRIPTOR",
                 "CQC_MODIFY qword0 includes reserved bit 21")

    status = rdma_cmq_codec_registry::lookup(RDMA_OP_SD_UPDATE,
                                             descriptor);
    expect_ok("SD_UPDATE_DESCRIPTOR", status);
    if (descriptor != null &&
        (descriptor.request_qword_masks[0] != 64'h0000_0000_0000_00ff ||
         descriptor.request_qword_masks[1] != 64'h0000_0001_ff00_0000 ||
         descriptor.request_qword_masks[2] != 64'h0000_0000_0000_0000 ||
         descriptor.request_qword_masks[3] != 64'hffff_ffff_ffff_fe00 ||
         descriptor.request_qword_masks[4] != 64'h0000_0000_0000_0fff ||
         descriptor.request_qword_masks[5] != 64'hffff_ffff_ffff_fff1 ||
         descriptor.request_qword_masks[6] != 64'h0000_0000_0000_0fff ||
         descriptor.request_qword_masks[7] != 64'hffff_ffff_ffff_fff1))
      `uvm_error("SD_UPDATE_DESCRIPTOR",
                 "SD_UPDATE ownership differs from cmq.c field writes")

    status = rdma_cmq_codec_registry::lookup(RDMA_OP_IFA_UPDATE,
                                             descriptor);
    expect_ok("IFA_UPDATE_DESCRIPTOR", status);
    if (descriptor != null &&
        (descriptor.request_qword_masks[0] != 64'h3000_0000_0000_0000 ||
         descriptor.request_qword_masks[1] != 64'h03ff_ffff_ffff_ffff ||
         descriptor.request_qword_masks[2] != 64'h0 ||
         descriptor.request_qword_masks[3] != 64'h0 ||
         descriptor.request_qword_masks[4] != 64'h0 ||
         descriptor.request_qword_masks[5] != 64'h0 ||
         descriptor.request_qword_masks[6] != 64'h0 ||
         descriptor.request_qword_masks[7] != 64'h0))
      `uvm_error("IFA_UPDATE_DESCRIPTOR",
                 "IFA_UPDATE ownership includes untouched qwords")

    // cmq.h 的请求布局只声明 qword1[57:0]；bit58 属于保留位，不能因为
    // IFA_QUERY 的响应布局允许 bit58 就被错误复制到 UPDATE 请求。
    if (descriptor != null) begin
      if (descriptor.request_qword_masks[1][58])
        `uvm_error("IFA_UPDATE_DESCRIPTOR",
                   "IFA_UPDATE qword1 bit58 is incorrectly admitted")
      if (!rdma_raw_qword_mask_is_valid(
            64'h03ff_ffff_ffff_ffff,
            descriptor.request_qword_masks[1]))
        `uvm_error("IFA_UPDATE_DESCRIPTOR",
                   "IFA_UPDATE qword1 bits57:0 are not fully admitted")
      if (rdma_raw_qword_mask_is_valid(
            64'h07ff_ffff_ffff_ffff,
            descriptor.request_qword_masks[1]))
        `uvm_error("IFA_UPDATE_DESCRIPTOR",
                   "IFA_UPDATE qword1 reserved bit58 was accepted")
    end

    status = rdma_cmq_codec_registry::lookup(RDMA_OP_CEQC_QUERY,
                                             descriptor);
    expect_ok("CEQC_QUERY_DESCRIPTOR", status);
    if (descriptor != null && descriptor.response_qword_masks[0] !=
                               64'h8000_3fff_ff00_0fff)
      `uvm_error("CEQC_QUERY_DESCRIPTOR",
                 "CEQC_QUERY EQN low field is not admitted")

    status = rdma_cmq_codec_registry::lookup(RDMA_OP_SRFQC_QUERY,
                                             descriptor);
    expect_ok("SRFQC_QUERY_DESCRIPTOR", status);
    if (descriptor != null && descriptor.response_qword_masks[0] !=
                               64'h8000_3fff_ff00_ffff)
      `uvm_error("SRFQC_QUERY_DESCRIPTOR",
                 "SRFQC_QUERY SRFQN field is not admitted")

    status = rdma_cmq_codec_registry::lookup(RDMA_OP_IFA_QUERY,
                                             descriptor);
    expect_ok("IFA_QUERY_DESCRIPTOR", status);
    if (descriptor != null && descriptor.response_qword_masks[0] !=
                               64'hb000_3fff_ff00_0000)
      `uvm_error("IFA_QUERY_DESCRIPTOR",
                 "IFA_QUERY object type is not admitted")
    if (descriptor != null) begin
      if (!descriptor.response_qword_masks[1][58] ||
          !rdma_raw_qword_mask_is_valid(
            64'h07ff_ffff_ffff_ffff,
            descriptor.response_qword_masks[1]))
        `uvm_error("IFA_QUERY_DESCRIPTOR",
                   "IFA_QUERY response qword1 bit58 is not admitted")
    end

    completion_codec = rdma_hw_cmq_completion_codec::type_id::create(
      "cmq_query_completion_codec");
    foreach (query_opcodes[query_index]) begin
      bit [7:0] query_opcode;
      bit query_ready;
      rdma_hw_cmq_completion query_completion;
      rdma_hw_image query_image;
      bit [63:0] query_qword0;
      bit [63:0] query_qword1;

      query_opcode = query_opcodes[query_index];

      query_qword0 = (query_opcode inside {
        RDMA_OP_CEQC_QUERY, RDMA_OP_AEQC_QUERY
      }) ? 64'h0000_0000_0000_0abc :
        (query_opcode == RDMA_OP_SRFQC_QUERY) ? 64'h0000_0000_0000_cdef :
        64'h1000_0000_0000_0000;
      query_qword1 = (query_opcode == RDMA_OP_IFA_QUERY) ?
        64'h0000_0000_0012_3456 : 64'h0000_0000_0000_0000;
      query_image = make_query_completion_image(
        query_opcode, query_qword0, query_qword1
      );
      query_completion = null;
      query_ready = 1'b0;
      status = completion_codec.inspect_completion(
        query_image, 1'b1, query_ready, query_completion
      );
      expect_ok($sformatf("QUERY_COMPLETION_%02x", query_opcode), status);
      if (!query_ready || query_completion == null)
        `uvm_error("QUERY_COMPLETION_PAYLOAD",
                   "driver query payload was not published")
    end

    status = rdma_cmq_codec_registry::lookup(RDMA_OP_OCC_QPC,
                                             descriptor);
    expect_ok("OCC_QPC_RESPONSE_DESCRIPTOR", status);
    if (descriptor != null && descriptor.response_qword_masks[0] !=
                               64'h83ff_ffff_ffff_0fff)
      `uvm_error("OCC_QPC_RESPONSE_DESCRIPTOR",
                 "OCC response return index is not a 12-bit field")

    completion_codec = rdma_hw_cmq_completion_codec::type_id::create(
      "cmq_occ_completion_codec");
    image = make_occ_completion_image(
      RDMA_OP_OCC_QPC, 12'h345, 8'h07, 12'h234,
      40'h12_3456_789a, 64'h0000_0000_0040_0000);
    completion = null;
    ready = 1'b0;
    status = completion_codec.inspect_completion(image, 1'b1, ready,
                                                 completion);
    expect_ok("OCC_QPC_COMPLETION", status);
    if (!ready || completion == null)
      `uvm_error("OCC_QPC_COMPLETION",
                 "driver OCC completion payload was not published")
  endfunction

  // 功能：在测试辅助 rdma_cmq_codec_test.check_envelope_oracle 中构造或驱动“envelope oracle”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_envelope_oracle();
    rdma_hw_cmq_envelope envelope;
    rdma_hw_cmq_envelope_codec envelope_codec;
    rdma_hw_image image;
    rdma_status status;
    bit [63:0] expected;

    envelope = make_envelope(RDMA_OP_OCC_FLUSH);
    envelope_codec = rdma_hw_cmq_envelope_codec::type_id::create(
      "envelope_oracle_codec");
    status = envelope_codec.encode(envelope, image);
    expect_ok("ENVELOPE_ORACLE_ENCODE", status);
    expected = (64'h1 << 63) | (64'h1 << 59) | (64'h345 << 48) |
               (64'h1 << 45) | (64'h1b << 40) |
               (64'(RDMA_OP_OCC_FLUSH) << 32);
    expect_word("ENVELOPE_ORACLE", image, 0, expected);
    for (int unsigned q = 1; q < 8; q++)
      expect_word("ENVELOPE_ORACLE", image, q, 0);
  endfunction

  // 功能：在测试辅助 rdma_cmq_codec_test.check_ownership_oracles 中构造或驱动“ownership oracles”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_ownership_oracles();
    bit [7:0] opcodes[12] = '{
      RDMA_OP_QPC_CREATE,
      RDMA_OP_QPC_MODIFY,
      RDMA_OP_QPC_DELETE,
      RDMA_OP_QPC_QUERY,
      RDMA_OP_KEY_ALLOC,
      RDMA_OP_MR_REGISTER,
      RDMA_OP_MR_DEREGISTER,
      RDMA_OP_OCC_FLUSH,
      RDMA_OP_CQC_DELETE,
      RDMA_OP_CEQC_DELETE,
      RDMA_OP_SRFQC_DELETE,
      RDMA_OP_TQ_FLUSH
    };
    rdma_image_kind_e expected_kinds[12] = '{
      RDMA_IMAGE_CMQ_SQE,
      RDMA_IMAGE_CMQ_SQE,
      RDMA_IMAGE_CMQ_SQE,
      RDMA_IMAGE_CMQ_SQE,
      RDMA_IMAGE_MRT,
      RDMA_IMAGE_MRT,
      RDMA_IMAGE_CMQ_SQE,
      RDMA_IMAGE_CMQ_SQE,
      RDMA_IMAGE_CMQ_SQE,
      RDMA_IMAGE_CMQ_SQE,
      RDMA_IMAGE_CMQ_SQE,
      RDMA_IMAGE_CMQ_SQE
    };
    string labels[12] = '{
      "QPC create", "QPC modify", "QPC delete", "QPC query",
      "MRT key allocate", "MRT register", "MR deregister", "OCC flush",
      "CQC context",
      "EQ object ID", "SRQ object ID", "empty body"
    };
    bit [63:0] expected_masks[12][8] = '{
      '{64'h0000000000ffffff, 64'hfffff801ff1fffff,
        64'h0000000000000000, 64'hfffffffffffffe00,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000},
      '{64'h7000000000ffffff, 64'hfffff801ff1fffff,
        64'hffffffff3fff3fff, 64'hfffffffffffffe00,
        64'hffffffffffffffff, 64'hffffffffffffffff,
        64'hffffffffffffffff, 64'hffffffffffffffff},
      '{64'h0000000000ffffff, 64'hfffff800001fffff,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000},
      '{64'h0000000000ffffff, 64'h0000000000000000,
        64'h0000000000000000, 64'hfffffffffffffe00,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000},
      '{64'h6000000000ffffff, 64'h00000000ff000000,
        64'hffffffffffffffff, 64'hff00bfffffffffff,
        64'hffffffffffffffff, 64'hfffffffffffff000,
        64'hffffffffffffffff, 64'h0000000000000000},
      '{64'h6000000000ffffff, 64'h00000000ff000000,
        64'hffffffffff000000, 64'hff00bfffffffffff,
        64'hffffffffffffffff, 64'hfffffffffffff000,
        64'hffffffffffffffff, 64'h0000000000000000},
      '{64'h6000000000ffffff, 64'h00000000ff000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000},
      '{64'h30000000001fffff, 64'hffc00fff00000000,
        64'hfffffffffffff000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000},
      '{64'h00000000001fffff, 64'hff0fffffffffffff,
        64'hfffffffffffff8ff, 64'hfffffffffff8c701,
        64'hf000000000ffffff, 64'h0000000000000fff,
        64'hffffffffffffffc0, 64'h0000000f00ffffff},
      '{64'h0000000000000fff, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000},
      '{64'h000000000000ffff, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000},
      '{64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000,
        64'h0000000000000000, 64'h0000000000000000}
    };
    rdma_image_kind_e actual_kind;
    bit [63:0] actual_masks[8];
    rdma_status status;

    foreach (opcodes[case_index]) begin
      status = ownership.lookup(opcodes[case_index], actual_kind,
                                actual_masks);
      expect_ok({"OWNERSHIP_ORACLE_", labels[case_index]}, status);
      if (!status.ok()) continue;
      if (actual_kind != expected_kinds[case_index])
        `uvm_error("OWNERSHIP_ORACLE",
                   $sformatf("%s kind %s, expected %s",
                             labels[case_index], actual_kind.name(),
                             expected_kinds[case_index].name()))
      foreach (actual_masks[q]) begin
        if (actual_masks[q] != expected_masks[case_index][q])
          `uvm_error("OWNERSHIP_ORACLE",
                     $sformatf(
                       "%s qword %0d mask 0x%016x, expected 0x%016x",
                       labels[case_index], q, actual_masks[q],
                       expected_masks[case_index][q]))
      end
    end
  endfunction

  // 功能：在测试辅助 rdma_cmq_codec_test.check_canonical_result 中构造或驱动“canonical result”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：label（输入）、opcode（输入）、body（输入）、result（输入）、signature_changes（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM
  //   assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  function automatic void check_canonical_result(
    string label,
    bit [7:0] opcode,
    rdma_hw_image body,
    rdma_hw_image result,
    bit signature_changes = 1'b0
  );
    rdma_image_kind_e input_kind;
    bit [63:0] masks[8];
    bit [63:0] body_expected;
    bit [63:0] actual;
    bit [63:0] signature_mask;
    rdma_status status;

    if (result == null) begin
      `uvm_error(label, "composition published null")
      return;
    end
    if (result.length != 64 || result.bytes.size() != 64 ||
        result.alignment != 64 || result.endian != RDMA_ENDIAN_BIG ||
        result.image_kind != RDMA_IMAGE_CMQ_SQE ||
        result.hardware_version != RDMA_HW_VERSION ||
        result.function_generation != body.function_generation ||
        result.write_target_kind != RDMA_HW_TARGET_NONE ||
        result.backing_target.value != 0 || result.hmc_target.value != 0 ||
        result.bar_target.value != 0)
      `uvm_error(label, "composed image metadata is not canonical")
    if (image_field(result, RDMA_CMQ_OPCODE_WORD_BYTE_OFFSET,
                    RDMA_CMQ_OPCODE_LSB,
                    RDMA_CMQ_OPCODE_WIDTH) != opcode)
      `uvm_error(label, "final request does not contain the exact opcode")

    status = ownership.lookup(opcode, input_kind, masks);
    expect_ok({label, "_OWNERSHIP_LOOKUP"}, status);
    signature_mask = 64'hff << RDMA_CMQ_SIGNATURE_LSB;
    for (int unsigned q = 0; q < 8; q++) begin
      actual = image_word(result, q);
      if ((actual & ~(request_envelope_mask(q) | masks[q])) != 0)
        `uvm_error(label,
                   $sformatf("qword %0d sets an unowned bit", q))
      body_expected = image_word(body, q) & masks[q];
      if (signature_changes && q == 1) begin
        if ((actual & masks[q] & ~signature_mask) !=
            (body_expected & ~signature_mask))
          `uvm_error(label, "composer changed non-signature body bits")
      end
      else if ((actual & masks[q]) != body_expected)
        `uvm_error(label,
                   $sformatf("composer changed body-owned qword %0d", q))
    end
  endfunction

  // 功能：在 rdma_cmq_codec_test 中，compose_ok 按 profile 的字段布局和端序把语义模型编码为硬件镜像，并在发布前检查长度与对齐。
  // 输入/输出及副作用：label（输入）、opcode（输入）、body（输入）、qpc_source（输入）、signature_changes（输入）；输入模型只读；成功时通过返回值或 output 发布完整
  //   image/bytes，不修改源模型。
  // 失败/边界：模型为空、字段越界、保留位非零或输出长度不足时返回编码错误，不发布部分图像。
  function automatic rdma_hw_image compose_ok(
    string label,
    bit [7:0] opcode,
    rdma_hw_image body,
    rdma_hw_image qpc_source = null,
    bit signature_changes = 1'b0
  );
    rdma_hw_cmq_envelope envelope;
    rdma_hw_cmq_envelope envelope_snapshot;
    rdma_hw_image result;
    rdma_hw_image body_snapshot;
    rdma_hw_image qpc_snapshot;
    rdma_status status;

    envelope = make_envelope(opcode);
    envelope_snapshot = snapshot_envelope(
      envelope, {label, "_ENVELOPE_SNAPSHOT"});
    body_snapshot = clone_image(body, {label, "_BODY_SNAPSHOT"});
    if (qpc_source != null)
      qpc_snapshot = clone_image(qpc_source, {label, "_QPC_SNAPSHOT"});
    result = rdma_hw_image::type_id::create({label, "_sentinel"});
    status = composer.compose_request(envelope, body, qpc_source, result);
    expect_ok({label, "_COMPOSE"}, status);
    check_canonical_result(label, opcode, body, result, signature_changes);
    if (!envelopes_equal(envelope, envelope_snapshot))
      `uvm_error(label, "composer mutated the envelope input")
    if (!images_equal(body, body_snapshot))
      `uvm_error(label, "composer mutated the body input")
    if (qpc_source != null && !images_equal(qpc_source, qpc_snapshot))
      `uvm_error(label, "composer mutated the QPC signature source")
    return result;
  endfunction

  // 功能：在 rdma_cmq_codec_test 中，expect_compose_failure 在测试中执行 expect_compose_failure 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、selected_composer（输入）、envelope（输入）、body（输入）、qpc_source（输入）、expected（输入）；fixture/输入由测试调用方提供；执行时会产生
  //   UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_compose_failure 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_compose_failure(
    string label,
    rdma_hw_cmq_request_composer selected_composer,
    rdma_hw_cmq_envelope envelope,
    rdma_hw_image body,
    rdma_hw_image qpc_source,
    rdma_status_code_e expected
  );
    rdma_hw_cmq_envelope envelope_snapshot;
    rdma_hw_image result;
    rdma_hw_image body_snapshot;
    rdma_hw_image qpc_snapshot;
    rdma_status status;
    envelope_snapshot = snapshot_envelope(
      envelope, {label, "_ENVELOPE_SNAPSHOT"});
    body_snapshot = clone_image(body, {label, "_BODY_SNAPSHOT"});
    if (qpc_source != null)
      qpc_snapshot = clone_image(qpc_source, {label, "_QPC_SNAPSHOT"});
    result = rdma_hw_image::type_id::create({label, "_sentinel"});
    status = selected_composer.compose_request(envelope, body, qpc_source,
                                               result);
    expect_status(label, status, expected);
    if (result != null)
      `uvm_error(label, "failed composition published a result")
    if (!envelopes_equal(envelope, envelope_snapshot))
      `uvm_error(label, "failed composition mutated envelope input")
    if (!images_equal(body, body_snapshot))
      `uvm_error(label, "failed composition mutated body input")
    if (qpc_source != null && !images_equal(qpc_source, qpc_snapshot))
      `uvm_error(label, "failed composition mutated QPC input")
  endfunction

  // 功能：在测试辅助 rdma_cmq_codec_test.check_signature 中构造或驱动“signature”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：label（输入）、opcode（输入）、body（输入）、qpc_source（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT
  //   转移未声明的资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  function automatic void check_signature(
    string label,
    bit [7:0] opcode,
    rdma_hw_image body,
    rdma_hw_image qpc_source
  );
    rdma_hw_cmq_envelope envelope;
    rdma_hw_cmq_envelope_codec envelope_codec;
    rdma_hw_image envelope_image;
    rdma_hw_image result;
    rdma_status status;
    byte unsigned expected_signature;
    byte unsigned final_xor;
    bit [63:0] unsigned_word;

    envelope = make_envelope(opcode);
    envelope_codec = rdma_hw_cmq_envelope_codec::type_id::create(
      {label, "_envelope_codec"});
    status = envelope_codec.encode(envelope, envelope_image);
    expect_ok({label, "_ENVELOPE"}, status);
    expected_signature = 8'h00;
    for (int unsigned q = 0; q < 8; q++) begin
      unsigned_word = image_word(envelope_image, q) | image_word(body, q);
      if (q == 1)
        unsigned_word &= ~(64'hff << RDMA_CMQ_SIGNATURE_LSB);
      for (int unsigned i = 0; i < 8; i++)
        expected_signature ^= unsigned_word[63 - (i * 8) -: 8];
    end
    foreach (qpc_source.bytes[i])
      expected_signature ^= qpc_source.bytes[i];
    expected_signature = ~expected_signature;

    result = compose_ok(label, opcode, body, qpc_source, 1'b1);
    if (image_field(result, RDMA_CMQ_SIGNATURE_WORD_BYTE_OFFSET,
                    RDMA_CMQ_SIGNATURE_LSB,
                    RDMA_CMQ_SIGNATURE_WIDTH) != expected_signature)
      `uvm_error(label, "composer signature differs from independent oracle")
    final_xor = 8'h00;
    foreach (result.bytes[i]) final_xor ^= result.bytes[i];
    foreach (qpc_source.bytes[i]) final_xor ^= qpc_source.bytes[i];
    if (final_xor != 8'hff)
      `uvm_error(label,
                 $sformatf("final WQE+QPC XOR is %02x, expected ff",
                           final_xor))
  endfunction

  // 功能：在测试辅助 rdma_cmq_codec_test.check_all_supported 中构造或驱动“all supported”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_all_supported();
    rdma_hw_qpc_command_body qpc_body;
    rdma_hw_cqc_delete_body cqc_delete_body;
    rdma_hw_object_id_command_body object_body;
    rdma_hw_mr_deregister_body dereg_body;
    rdma_hw_occ_flush_body occ_body;
    rdma_hw_image body;
    rdma_hw_image key_zero_image;
    rdma_hw_image register_zero_image;
    rdma_hw_image key_nonzero_image;
    rdma_hw_image key_pbl1_image;
    rdma_hw_image key_pbl2_image;
    rdma_hw_image qpc_source;
    rdma_hw_image cqc_context_image;
    rdma_hw_image result;
    rdma_status status;
    rdma_hw_cmq_envelope envelope;
    rdma_mrt_model mrt_zero;
    rdma_cqc_model cqc_context;

    qpc_source = make_qpc_signature_source();

    qpc_body = make_qpc_body("qpc_create_body", RDMA_OP_QPC_CREATE);
    body = encode_light("QPC_CREATE", RDMA_OP_QPC_CREATE, qpc_body);
    expect_word("QPC_CREATE_BODY", body, 0, 64'h0000_0000_0001_2345);
    expect_word("QPC_CREATE_BODY", body, 1,
                (64'h15555 << 43) | (64'h1 << 32) | 64'h0aaaa);
    expect_word("QPC_CREATE_BODY", body, 2, 0);
    expect_word("QPC_CREATE_BODY", body, 3,
                64'h0000_2468_ace0_0000);
    for (int unsigned q = 4; q < 8; q++)
      expect_word("QPC_CREATE_BODY", body, q, 0);
    if (image_field(body, RDMA_CMQ_SIGNATURE_WORD_BYTE_OFFSET,
                    RDMA_CMQ_SIGNATURE_LSB,
                    RDMA_CMQ_SIGNATURE_WIDTH) != 0)
      `uvm_error("QPC_CREATE", "unsigned body signature is not zero")
    check_signature("QPC_CREATE", RDMA_OP_QPC_CREATE, body, qpc_source);

    qpc_body = make_qpc_body("qpc_full_modify_body",
                             RDMA_OP_QPC_MODIFY,
                             RDMA_QPC_MODIFY_FULL);
    body = encode_light("QPC_MODIFY_FULL", RDMA_OP_QPC_MODIFY,
                        qpc_body);
    expect_word("QPC_MODIFY_FULL_BODY", body, 0,
                (64'h3 << 60) | 64'h12345);
    expect_word("QPC_MODIFY_FULL_BODY", body, 1,
                (64'h15555 << 43) | (64'h1 << 32) | 64'h0aaaa);
    expect_word("QPC_MODIFY_FULL_BODY", body, 2,
                64'h1 << 62);
    expect_word("QPC_MODIFY_FULL_BODY", body, 3,
                64'h0000_2468_ace0_0000);
    for (int unsigned q = 4; q < 8; q++)
      expect_word("QPC_MODIFY_FULL_BODY", body, q, 0);
    check_signature("QPC_MODIFY_FULL", RDMA_OP_QPC_MODIFY, body,
                    qpc_source);

    qpc_body = make_qpc_body("qpc_state_modify_body",
                             RDMA_OP_QPC_MODIFY);
    body = encode_light("QPC_MODIFY_STATE", RDMA_OP_QPC_MODIFY,
                        qpc_body);
    expect_word("QPC_MODIFY_STATE_BODY", body, 0,
                (64'h3 << 60) | 64'h12345);
    expect_word("QPC_MODIFY_STATE_BODY", body, 1,
                (64'h15555 << 43) | 64'h0aaaa);
    expect_word("QPC_MODIFY_STATE_BODY", body, 2, 0);
    for (int unsigned q = 3; q < 8; q++)
      expect_word("QPC_MODIFY_STATE_BODY", body, q, 0);
    void'(compose_ok("QPC_MODIFY_STATE", RDMA_OP_QPC_MODIFY, body));

    qpc_body = make_qpc_body("qpc_partial_modify_body",
                             RDMA_OP_QPC_MODIFY,
                             RDMA_QPC_MODIFY_PARTIAL);
    body = encode_light("QPC_MODIFY_PARTIAL", RDMA_OP_QPC_MODIFY,
                        qpc_body);
    expect_word("QPC_MODIFY_PARTIAL_BODY", body, 0,
                (64'h3 << 60) | 64'h12345);
    expect_word("QPC_MODIFY_PARTIAL_BODY", body, 1,
                (64'h15555 << 43) | 64'h0aaaa);
    expect_word("QPC_MODIFY_PARTIAL_BODY", body, 2,
                (64'h2 << 62) | (64'h2 << 56) | (64'h81 << 48) |
                (64'h1 << 46) | (64'h9 << 40) | (64'h40 << 32) |
                (64'h10 << 24) | (64'h20 << 16) | (64'h17 << 8) |
                64'h10);
    expect_word("QPC_MODIFY_PARTIAL_BODY", body, 3, 0);
    for (int unsigned q = 4; q < 8; q++)
      expect_word("QPC_MODIFY_PARTIAL_BODY", body, q,
                  64'h1020_3040_5060_7080 ^ (q - 4));
    if (image_field(body, RDMA_CMQ_SIGN_EN_WORD_BYTE_OFFSET,
                    RDMA_CMQ_SIGN_EN_LSB,
                    RDMA_CMQ_SIGN_EN_WIDTH) != 0 ||
        image_field(body, RDMA_CMQ_SIGNATURE_WORD_BYTE_OFFSET,
                    RDMA_CMQ_SIGNATURE_LSB,
                    RDMA_CMQ_SIGNATURE_WIDTH) != 0)
      `uvm_error("QPC_MODIFY_PARTIAL",
                 "partial modify unexpectedly enables a signature")
    envelope = make_envelope(RDMA_OP_QPC_MODIFY);
    expect_compose_failure("PARTIAL_REJECTS_QPC_SOURCE", composer, envelope,
                           body, qpc_source, RDMA_SC_CODEC_ERROR);
    void'(compose_ok("QPC_MODIFY_PARTIAL", RDMA_OP_QPC_MODIFY, body));

    qpc_body = make_qpc_body("qpc_delete_body", RDMA_OP_QPC_DELETE);
    body = encode_light("QPC_DELETE", RDMA_OP_QPC_DELETE, qpc_body);
    expect_word("QPC_DELETE_BODY", body, 0, 64'h12345);
    expect_word("QPC_DELETE_BODY", body, 1,
                (64'h15555 << 43) | 64'h0aaaa);
    for (int unsigned q = 2; q < 8; q++)
      expect_word("QPC_DELETE_BODY", body, q, 0);
    void'(compose_ok("QPC_DELETE", RDMA_OP_QPC_DELETE, body));

    qpc_body = make_qpc_body("qpc_query_body", RDMA_OP_QPC_QUERY);
    body = encode_light("QPC_QUERY", RDMA_OP_QPC_QUERY, qpc_body);
    void'(compose_ok("QPC_QUERY", RDMA_OP_QPC_QUERY, body));

    qpc_body = make_qpc_body("qpc_minimal_query_body",
                             RDMA_OP_QPC_QUERY);
    body = encode_light("QPC_MINIMAL_QUERY", RDMA_OP_QPC_QUERY,
                        qpc_body);
    if (body == null)
      `uvm_error("QPC_MINIMAL_QUERY", "valid minimal query published null")
    else begin
      expect_word("QPC_MINIMAL_QUERY_BODY", body, 0, 64'h0000_0000_0001_2345);
      expect_word("QPC_MINIMAL_QUERY_BODY", body, 1, 64'h0);
      expect_word("QPC_MINIMAL_QUERY_BODY", body, 2, 64'h0);
      expect_word("QPC_MINIMAL_QUERY_BODY", body, 3,
                  64'h0000_2468_ace0_0000);
      for (int unsigned q = 4; q < 8; q++)
        expect_word("QPC_MINIMAL_QUERY_BODY", body, q, 64'h0);
      void'(compose_ok("QPC_MINIMAL_QUERY", RDMA_OP_QPC_QUERY, body));
    end

    mrt_zero = make_mrt("mrt_zero", 0);
    key_zero_image = encode_context("KEY_ALLOC_ZERO", RDMA_OP_KEY_ALLOC,
                                    mrt_zero);
    register_zero_image = encode_context("MR_REGISTER_ZERO",
                                         RDMA_OP_MR_REGISTER, mrt_zero);
    if (!images_equal(key_zero_image, register_zero_image))
      `uvm_error("STAG0_PROVENANCE",
                 "STAG0 key/register precondition is not byte-identical")
    void'(compose_ok("KEY_ALLOC_ZERO", RDMA_OP_KEY_ALLOC,
                     key_zero_image));
    void'(compose_ok("MR_REGISTER_ZERO", RDMA_OP_MR_REGISTER,
                     register_zero_image));
    key_nonzero_image = encode_context("KEY_ALLOC_NONZERO",
                                       RDMA_OP_KEY_ALLOC,
                                       make_mrt("mrt_nonzero", 1));
    key_pbl1_image = encode_context(
      "KEY_ALLOC_PBL1", RDMA_OP_KEY_ALLOC,
      make_mrt("mrt_key_pbl1", 24'h123456, RDMA_MR_PBL1));
    if (key_pbl1_image != null)
      void'(compose_ok("KEY_ALLOC_PBL1", RDMA_OP_KEY_ALLOC,
                       key_pbl1_image));
    key_pbl2_image = encode_context(
      "KEY_ALLOC_PBL2", RDMA_OP_KEY_ALLOC,
      make_mrt("mrt_key_pbl2", 24'h654321, RDMA_MR_PBL2));
    if (key_pbl2_image != null)
      void'(compose_ok("KEY_ALLOC_PBL2", RDMA_OP_KEY_ALLOC,
                       key_pbl2_image));
    envelope = make_envelope(RDMA_OP_MR_REGISTER);
    expect_compose_failure("KEY_ALLOC_NONZERO_AS_REGISTER", composer,
                           envelope, key_nonzero_image, null,
                           RDMA_SC_CODEC_ERROR);

    dereg_body = rdma_hw_mr_deregister_body::type_id::create(
      "mr_deregister_body");
    dereg_body.mr_h = make_handle("dereg_mr", RDMA_RESOURCE_MR, 24'h654321);
    dereg_body.stag_key = 8'hd3;
    dereg_body.next_state = RDMA_CONTEXT_VALID;
    body = encode_light("MR_DEREGISTER", RDMA_OP_MR_DEREGISTER,
                        dereg_body);
    expect_word("MR_DEREGISTER_BODY", body, 0, 64'h4000_0000_0065_4321);
    expect_word("MR_DEREGISTER_BODY", body, 1, 64'h0000_0000_d300_0000);
    for (int unsigned q = 2; q < 8; q++)
      expect_word("MR_DEREGISTER_BODY", body, q, 0);
    void'(compose_ok("MR_DEREGISTER", RDMA_OP_MR_DEREGISTER, body));

    occ_body = make_occ_vf("occ_vf_flush");
    body = encode_light("OCC_VF_FLUSH", RDMA_OP_OCC_FLUSH, occ_body);
    expect_word("OCC_VF_FLUSH", body, 0, 64'h2000_0000_0000_0000);
    expect_word("OCC_VF_FLUSH", body, 1, 64'hff80_0000_0000_0000);
    void'(compose_ok("OCC_VF_FLUSH", RDMA_OP_OCC_FLUSH, body));

    occ_body = make_occ_serial("occ_serial_flush");
    body = encode_light("OCC_SERIAL_FLUSH", RDMA_OP_OCC_FLUSH, occ_body);
    expect_word("OCC_SERIAL_FLUSH", body, 0, 64'h1000_0000_0000_0000);
    expect_word("OCC_SERIAL_FLUSH", body, 1, 64'h1000_0abc_0000_0000);
    void'(compose_ok("OCC_SERIAL_FLUSH", RDMA_OP_OCC_FLUSH, body));

    occ_body = make_occ_qpn("occ_qpn_flush");
    body = encode_light("OCC_QPN_FLUSH", RDMA_OP_OCC_FLUSH, occ_body);
    expect_word("OCC_QPN_FLUSH", body, 0, 64'h0000_0000_0001_2345);
    expect_word("OCC_QPN_FLUSH", body, 1, 64'h0380_0000_0000_0000);
    void'(compose_ok("OCC_QPN_FLUSH", RDMA_OP_OCC_FLUSH, body));

    occ_body = make_occ_qpn_pd("occ_qpn_pd_flush");
    body = encode_light("OCC_QPN_PD_FLUSH", RDMA_OP_OCC_FLUSH, occ_body);
    expect_word("OCC_QPN_PD_FLUSH", body, 0, 64'h0000_0000_0001_2345);
    expect_word("OCC_QPN_PD_FLUSH", body, 1, 64'h0040_0000_0000_0000);
    expect_word("OCC_QPN_PD_FLUSH", body, 2,
                64'h0000_0000_0600_0000);
    void'(compose_ok("OCC_QPN_PD_FLUSH", RDMA_OP_OCC_FLUSH, body));

    occ_body = make_occ_pd("occ_pd_flush");
    body = encode_light("OCC_PD_FLUSH", RDMA_OP_OCC_FLUSH, occ_body);
    expect_word("OCC_PD_FLUSH", body, 0, 0);
    expect_word("OCC_PD_FLUSH", body, 1, 64'h0040_0000_0000_0000);
    expect_word("OCC_PD_FLUSH", body, 2, 64'h0000_0000_0600_0000);
    void'(compose_ok("OCC_PD_FLUSH", RDMA_OP_OCC_FLUSH, body));

    cqc_context = make_cqc();
    cqc_context_image = encode_context(
      "CQC_CREATE", RDMA_OP_CQC_CREATE, cqc_context
    );
    body = cqc_context_image;
    void'(compose_ok("CQC_CREATE", RDMA_OP_CQC_CREATE, body));
    cqc_delete_body = make_cqc_delete_body("cqc_delete");
    cqc_delete_body.cqc_context = cqc_context;
    body = encode_light("CQC_DELETE", RDMA_OP_CQC_DELETE,
                        cqc_delete_body);
    expect_word("CQC_DELETE_BODY", body, 0, 64'h12345);
    for (int unsigned q = 1; q < 8; q++)
      expect_word("CQC_DELETE_BODY", body, q,
                  image_word(cqc_context_image, q));
    void'(compose_ok("CQC_DELETE", RDMA_OP_CQC_DELETE, body));
    object_body = make_object_body("cqc_delete", RDMA_RESOURCE_CQ,
                                   21'h12345);
    expect_light_failure("CQC_DELETE_REJECTS_GENERIC_BODY",
                         RDMA_OP_CQC_DELETE, object_body,
                         RDMA_SC_INVALID_ARGUMENT);
    body = encode_light("CQC_QUERY", RDMA_OP_CQC_QUERY, object_body);
    void'(compose_ok("CQC_QUERY", RDMA_OP_CQC_QUERY, body));

    body = encode_context("CEQC_CREATE", RDMA_OP_CEQC_CREATE, make_ceqc());
    void'(compose_ok("CEQC_CREATE", RDMA_OP_CEQC_CREATE, body));
    object_body = make_object_body("ceqc_delete", RDMA_RESOURCE_CEQ,
                                   12'habc);
    body = encode_light("CEQC_DELETE", RDMA_OP_CEQC_DELETE, object_body);
    expect_word("CEQC_DELETE_BODY", body, 0, 64'habc);
    for (int unsigned q = 1; q < 8; q++)
      expect_word("CEQC_DELETE_BODY", body, q, 0);
    void'(compose_ok("CEQC_DELETE", RDMA_OP_CEQC_DELETE, body));
    body = encode_light("CEQC_QUERY", RDMA_OP_CEQC_QUERY, object_body);
    void'(compose_ok("CEQC_QUERY", RDMA_OP_CEQC_QUERY, body));

    body = encode_context("AEQC_CREATE", RDMA_OP_AEQC_CREATE, make_aeqc());
    void'(compose_ok("AEQC_CREATE", RDMA_OP_AEQC_CREATE, body));
    object_body = make_object_body("aeqc_delete", RDMA_RESOURCE_AEQ,
                                   12'h789);
    body = encode_light("AEQC_DELETE", RDMA_OP_AEQC_DELETE, object_body);
    expect_word("AEQC_DELETE_BODY", body, 0, 64'h789);
    for (int unsigned q = 1; q < 8; q++)
      expect_word("AEQC_DELETE_BODY", body, q, 0);
    void'(compose_ok("AEQC_DELETE", RDMA_OP_AEQC_DELETE, body));
    body = encode_light("AEQC_QUERY", RDMA_OP_AEQC_QUERY, object_body);
    void'(compose_ok("AEQC_QUERY", RDMA_OP_AEQC_QUERY, body));

    body = encode_light("TQ_FLUSH", RDMA_OP_TQ_FLUSH, null);
    for (int unsigned q = 0; q < 8; q++)
      expect_word("TQ_FLUSH_BODY", body, q, 0);
    void'(compose_ok("TQ_FLUSH", RDMA_OP_TQ_FLUSH, body));

    body = encode_context("SRFQC_CREATE", RDMA_OP_SRFQC_CREATE,
                          make_srqc());
    void'(compose_ok("SRFQC_CREATE", RDMA_OP_SRFQC_CREATE, body));
    object_body = make_object_body("srfqc_delete", RDMA_RESOURCE_SRQ,
                                   16'hcdef);
    body = encode_light("SRFQC_DELETE", RDMA_OP_SRFQC_DELETE, object_body);
    expect_word("SRFQC_DELETE_BODY", body, 0, 64'hcdef);
    for (int unsigned q = 1; q < 8; q++)
      expect_word("SRFQC_DELETE_BODY", body, q, 0);
    void'(compose_ok("SRFQC_DELETE", RDMA_OP_SRFQC_DELETE, body));
    body = encode_light("SRFQC_QUERY", RDMA_OP_SRFQC_QUERY, object_body);
    void'(compose_ok("SRFQC_QUERY", RDMA_OP_SRFQC_QUERY, body));
  endfunction

  // 功能：在测试辅助 rdma_cmq_codec_test.check_qpc_full_modify_templates 中构造或驱动“qpc full modify templates”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_qpc_full_modify_templates();
    rdma_hw_qpc_command_body qpc_body;
    rdma_hw_cmq_envelope envelope;
    rdma_hw_image body;
    rdma_hw_image rc_source;
    rdma_hw_image ud_source;
    rdma_hw_image urc_source;

    rc_source = make_qpc_signature_source(21'h12345, "rc");
    ud_source = make_qpc_signature_source(21'h12345, "ud");
    urc_source = make_qpc_signature_source(21'h12345, "urc");

    qpc_body = make_qpc_body("full_modify_rc",
                             RDMA_OP_QPC_MODIFY,
                             RDMA_QPC_MODIFY_FULL);
    qpc_body.wbe_template_count = 0;
    body = encode_light("QPC_FULL_RC_TEMPLATE_0",
                        RDMA_OP_QPC_MODIFY, qpc_body);
    check_signature("QPC_FULL_RC_TEMPLATE_0", RDMA_OP_QPC_MODIFY,
                    body, rc_source);

    qpc_body = make_qpc_body("full_modify_ud",
                             RDMA_OP_QPC_MODIFY,
                             RDMA_QPC_MODIFY_FULL);
    qpc_body.wbe_template_count = 0;
    body = encode_light("QPC_FULL_UD_TEMPLATE_0",
                        RDMA_OP_QPC_MODIFY, qpc_body);
    check_signature("QPC_FULL_UD_TEMPLATE_0", RDMA_OP_QPC_MODIFY,
                    body, ud_source);

    qpc_body = make_qpc_body("full_modify_urc",
                             RDMA_OP_QPC_MODIFY,
                             RDMA_QPC_MODIFY_FULL);
    qpc_body.wbe_template_count = 1;
    body = encode_light("QPC_FULL_URC_TEMPLATE_1",
                        RDMA_OP_QPC_MODIFY, qpc_body);
    check_signature("QPC_FULL_URC_TEMPLATE_1", RDMA_OP_QPC_MODIFY,
                    body, urc_source);

    envelope = make_envelope(RDMA_OP_QPC_MODIFY);
    qpc_body = make_qpc_body("full_modify_rc_bad_template",
                             RDMA_OP_QPC_MODIFY,
                             RDMA_QPC_MODIFY_FULL);
    qpc_body.wbe_template_count = 1;
    body = encode_light("QPC_FULL_RC_TEMPLATE_1",
                        RDMA_OP_QPC_MODIFY, qpc_body);
    expect_compose_failure("QPC_FULL_REJECTS_RC_TEMPLATE_1", composer,
                           envelope, body, rc_source, RDMA_SC_CODEC_ERROR);

    qpc_body = make_qpc_body("full_modify_ud_bad_template",
                             RDMA_OP_QPC_MODIFY,
                             RDMA_QPC_MODIFY_FULL);
    qpc_body.wbe_template_count = 1;
    body = encode_light("QPC_FULL_UD_TEMPLATE_1",
                        RDMA_OP_QPC_MODIFY, qpc_body);
    expect_compose_failure("QPC_FULL_REJECTS_UD_TEMPLATE_1", composer,
                           envelope, body, ud_source, RDMA_SC_CODEC_ERROR);

    qpc_body = make_qpc_body("full_modify_urc_bad_template",
                             RDMA_OP_QPC_MODIFY,
                             RDMA_QPC_MODIFY_FULL);
    qpc_body.wbe_template_count = 0;
    body = encode_light("QPC_FULL_URC_TEMPLATE_0",
                        RDMA_OP_QPC_MODIFY, qpc_body);
    expect_compose_failure("QPC_FULL_REJECTS_URC_TEMPLATE_0", composer,
                           envelope, body, urc_source, RDMA_SC_CODEC_ERROR);
  endfunction

  // 功能：在测试辅助 rdma_cmq_codec_test.check_provenance_cross_pairs 中构造或驱动“provenance cross pairs”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_provenance_cross_pairs();
    rdma_hw_object_id_command_body object_body;
    rdma_hw_image cqc_query;
    rdma_hw_image ceqc_delete;
    rdma_hw_image tq_empty;
    rdma_hw_image key_zero;
    rdma_hw_image register_zero;
    rdma_hw_cmq_envelope envelope;
    rdma_status status;

    object_body = make_object_body("cross_cqc_query", RDMA_RESOURCE_CQ,
                                   21'h12345);
    cqc_query = encode_light("CROSS_CQC_QUERY", RDMA_OP_CQC_QUERY,
                             object_body);
    envelope = make_envelope(RDMA_OP_CQC_DELETE);
    expect_compose_failure("CQC_QUERY_AS_DELETE", composer, envelope,
                           cqc_query, null, RDMA_SC_CODEC_ERROR);

    object_body = make_object_body("cross_ceqc_delete", RDMA_RESOURCE_CEQ,
                                   12'h789);
    ceqc_delete = encode_light("CROSS_CEQC_DELETE", RDMA_OP_CEQC_DELETE,
                               object_body);
    envelope = make_envelope(RDMA_OP_AEQC_DELETE);
    expect_compose_failure("CEQC_DELETE_AS_AEQC_DELETE", composer, envelope,
                           ceqc_delete, null, RDMA_SC_CODEC_ERROR);

    status = light.encode(RDMA_OP_TQ_FLUSH, null, tq_empty);
    expect_ok("CROSS_TQ_EMPTY_ENCODE", status);
    envelope = make_envelope(RDMA_OP_QPC_QUERY);
    expect_compose_failure("TQ_EMPTY_AS_QPC_QUERY", composer, envelope,
                           tq_empty, null, RDMA_SC_CODEC_ERROR);

    key_zero = encode_context("CROSS_KEY_ALLOC", RDMA_OP_KEY_ALLOC,
                              make_mrt("cross_key_zero", 0));
    register_zero = encode_context("CROSS_MR_REGISTER",
                                   RDMA_OP_MR_REGISTER,
                                   make_mrt("cross_register_zero", 0));
    envelope = make_envelope(RDMA_OP_MR_REGISTER);
    expect_compose_failure("KEY_ALLOC_AS_MR_REGISTER", composer, envelope,
                           key_zero, null, RDMA_SC_CODEC_ERROR);
    envelope = make_envelope(RDMA_OP_KEY_ALLOC);
    expect_compose_failure("MR_REGISTER_AS_KEY_ALLOC", composer, envelope,
                           register_zero, null, RDMA_SC_CODEC_ERROR);
  endfunction

  // 功能：在测试辅助 rdma_cmq_codec_test.check_artifact_contract 中构造或驱动“artifact contract”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_artifact_contract();
    rdma_hw_qpc_command_body qpc_body;
    rdma_hw_object_id_command_body object_body;
    rdma_hw_cmq_request_composer foreign_composer;
    rdma_hw_cmq_envelope envelope;
    rdma_hw_cmq_test_forged_body forged;
    rdma_hw_image base;
    rdma_hw_image raw;
    rdma_hw_image foreign_body;
    rdma_hw_image query_body;
    rdma_hw_image bad;
    rdma_hw_image qpc_source;
    rdma_hw_image result;
    rdma_status status;

    qpc_body = make_qpc_body("artifact_qpc", RDMA_OP_QPC_CREATE);
    base = encode_light("ARTIFACT_BASE", RDMA_OP_QPC_CREATE, qpc_body);
    qpc_source = make_qpc_signature_source();
    envelope = make_envelope(RDMA_OP_QPC_CREATE);

    raw = rdma_hw_image::type_id::create("artifact_raw_copy");
    raw.copy(base);
    expect_compose_failure("ARTIFACT_REJECTS_RAW", composer, envelope,
                           raw, qpc_source, RDMA_SC_CODEC_ERROR);

    foreign_composer = new("foreign_artifact_composer", ownership);
    status = foreign_composer.build_body(RDMA_OP_QPC_CREATE, qpc_body,
                                         foreign_body);
    expect_ok("ARTIFACT_FOREIGN_ENCODE", status);
    expect_compose_failure("ARTIFACT_REJECTS_FOREIGN", composer, envelope,
                           foreign_body, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = clone_image(base, "artifact_exact_clone");
    expect_compose_failure("ARTIFACT_REJECTS_EXACT_CLONE", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    object_body = make_object_body("artifact_relabel_query",
                                   RDMA_RESOURCE_CQ, 21'h12345);
    query_body = encode_light("ARTIFACT_RELABEL_QUERY",
                              RDMA_OP_CQC_QUERY, object_body);
    forged = new("artifact_forged_delete");
    forged.copy_and_relabel_attempt(query_body);
    envelope = make_envelope(RDMA_OP_CQC_DELETE);
    expect_compose_failure("ARTIFACT_REJECTS_COPY_RELABEL", composer,
                           envelope, forged, null, RDMA_SC_CODEC_ERROR);
    envelope = make_envelope(RDMA_OP_QPC_CREATE);

    bad = encode_light("ARTIFACT_MUTABLE_BYTES", RDMA_OP_QPC_CREATE,
                       qpc_body);
    bad.bytes[0] ^= 8'h01;
    expect_compose_failure("ARTIFACT_REJECTS_BYTE_MUTATION", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_GENERATION",
                       RDMA_OP_QPC_CREATE, qpc_body);
    bad.function_generation++;
    expect_compose_failure("ARTIFACT_REJECTS_METADATA_MUTATION", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_LENGTH", RDMA_OP_QPC_CREATE,
                       qpc_body);
    bad.length++;
    expect_compose_failure("ARTIFACT_REJECTS_LENGTH_MUTATION", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_ALIGNMENT", RDMA_OP_QPC_CREATE,
                       qpc_body);
    bad.alignment = 8;
    expect_compose_failure("ARTIFACT_REJECTS_ALIGNMENT_MUTATION", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_ENDIAN", RDMA_OP_QPC_CREATE,
                       qpc_body);
    bad.endian = RDMA_ENDIAN_LITTLE;
    expect_compose_failure("ARTIFACT_REJECTS_ENDIAN_MUTATION", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_KIND", RDMA_OP_QPC_CREATE,
                       qpc_body);
    bad.image_kind = RDMA_IMAGE_CQC;
    expect_compose_failure("ARTIFACT_REJECTS_KIND_MUTATION", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_VERSION", RDMA_OP_QPC_CREATE,
                       qpc_body);
    bad.hardware_version++;
    expect_compose_failure("ARTIFACT_REJECTS_VERSION_MUTATION", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_SUMMARY", RDMA_OP_QPC_CREATE,
                       qpc_body);
    bad.field_summary.push_back("mutated after exact encode");
    if (images_equal(base, bad))
      `uvm_error("IMAGES_EQUAL_FIELD_SUMMARY",
                 "image comparison ignored field_summary")
    expect_compose_failure("ARTIFACT_REJECTS_SUMMARY_MUTATION", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_SIZE", RDMA_OP_QPC_CREATE,
                       qpc_body);
    void'(bad.bytes.pop_back());
    expect_compose_failure("BODY_REJECTS_BYTE_COUNT", composer, envelope,
                           bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_TARGET_KIND",
                       RDMA_OP_QPC_CREATE, qpc_body);
    bad.write_target_kind = RDMA_HW_TARGET_BACKING;
    expect_compose_failure("BODY_REJECTS_TARGET_KIND", composer, envelope,
                           bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_BACKING",
                       RDMA_OP_QPC_CREATE, qpc_body);
    bad.backing_target.value = 64'h1000;
    expect_compose_failure("BODY_REJECTS_BACKING_TARGET", composer,
                           envelope, bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_HMC", RDMA_OP_QPC_CREATE,
                       qpc_body);
    bad.hmc_target.value = 64'h1000;
    expect_compose_failure("BODY_REJECTS_HMC_TARGET", composer, envelope,
                           bad, qpc_source, RDMA_SC_CODEC_ERROR);

    bad = encode_light("ARTIFACT_MUTABLE_BAR", RDMA_OP_QPC_CREATE,
                       qpc_body);
    bad.bar_target.value = 64'h1000;
    expect_compose_failure("BODY_REJECTS_BAR_TARGET", composer, envelope,
                           bad, qpc_source, RDMA_SC_CODEC_ERROR);

    result = compose_ok("ARTIFACT_CANONICAL_GENERATION",
                        RDMA_OP_QPC_CREATE, base, qpc_source, 1'b1);
    if (result != null &&
        result.function_generation != base.function_generation)
      `uvm_error("ARTIFACT_CANONICAL_GENERATION",
                 "composed request did not preserve body generation")
  endfunction

  // 功能：在测试辅助 rdma_cmq_codec_test.check_artifact_lifecycle 中构造或驱动“artifact lifecycle”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_artifact_lifecycle();
    rdma_hw_cmq_envelope envelope;
    rdma_hw_image body;
    rdma_hw_image result;
    rdma_status status;

    for (int unsigned i = 0; i < 256; i++) begin
      body = null;
      status = composer.build_body(RDMA_OP_TQ_FLUSH, null, body);
      expect_ok("ARTIFACT_LIFECYCLE_BUILD", status);
      envelope = make_envelope(RDMA_OP_TQ_FLUSH);
      envelope.wqe_index = i[4:0];
      result = null;
      status = composer.compose_request(envelope, body, null, result);
      expect_ok("ARTIFACT_LIFECYCLE_COMPOSE", status);
      if (result == null)
        `uvm_error("ARTIFACT_LIFECYCLE_COMPOSE",
                   "successful repeated composition published null")
    end
  endfunction

  // 功能：在测试辅助 rdma_cmq_codec_test.check_qpc_light_semantics 中构造或驱动“qpc light semantics”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_qpc_light_semantics();
    rdma_hw_qpc_command_body qpc_body;
    rdma_hw_object_id_command_body wrong_model;

    qpc_body = make_qpc_body("create_with_state", RDMA_OP_QPC_CREATE);
    qpc_body.next_state = RDMA_QPS_RTS;
    expect_light_failure("QPC_CREATE_REJECTS_STATE", RDMA_OP_QPC_CREATE,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("create_with_wbe", RDMA_OP_QPC_CREATE);
    qpc_body.wbe_template_count = 1;
    expect_light_failure("QPC_CREATE_REJECTS_WBE", RDMA_OP_QPC_CREATE,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("create_with_pair", RDMA_OP_QPC_CREATE);
    qpc_body.modify_start_qword[0] = 1;
    qpc_body.modify_wbe[0] = 8'hff;
    expect_light_failure("QPC_CREATE_REJECTS_PAIR", RDMA_OP_QPC_CREATE,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("create_with_data", RDMA_OP_QPC_CREATE);
    qpc_body.modify_data[0] = 64'h1;
    expect_light_failure("QPC_CREATE_REJECTS_DATA", RDMA_OP_QPC_CREATE,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);

    qpc_body = make_qpc_body("full_with_urc_wbe", RDMA_OP_QPC_MODIFY,
                             RDMA_QPC_MODIFY_FULL);
    qpc_body.wbe_template_count = 1;
    void'(encode_light("QPC_FULL_ACCEPTS_URC_WBE",
                       RDMA_OP_QPC_MODIFY, qpc_body));
    qpc_body = make_qpc_body("full_with_invalid_wbe",
                             RDMA_OP_QPC_MODIFY,
                             RDMA_QPC_MODIFY_FULL);
    qpc_body.wbe_template_count = 2;
    expect_light_failure("QPC_FULL_REJECTS_INVALID_WBE",
                         RDMA_OP_QPC_MODIFY,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("full_with_pair", RDMA_OP_QPC_MODIFY,
                             RDMA_QPC_MODIFY_FULL);
    qpc_body.modify_start_qword[0] = 1;
    expect_light_failure("QPC_FULL_REJECTS_PAIR", RDMA_OP_QPC_MODIFY,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("full_with_data", RDMA_OP_QPC_MODIFY,
                             RDMA_QPC_MODIFY_FULL);
    qpc_body.modify_data[0] = 64'h1;
    expect_light_failure("QPC_FULL_REJECTS_DATA", RDMA_OP_QPC_MODIFY,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);

    qpc_body = make_qpc_body("partial_with_buffer", RDMA_OP_QPC_MODIFY,
                             RDMA_QPC_MODIFY_PARTIAL);
    qpc_body.qpc_buffer.value = 64'h200;
    expect_light_failure("QPC_PARTIAL_REJECTS_BUFFER",
                         RDMA_OP_QPC_MODIFY, qpc_body,
                         RDMA_SC_INVALID_ARGUMENT);

    qpc_body = make_qpc_body("state_with_wbe", RDMA_OP_QPC_MODIFY);
    qpc_body.wbe_template_count = 1;
    expect_light_failure("QPC_STATE_REJECTS_WBE", RDMA_OP_QPC_MODIFY,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("state_with_pair", RDMA_OP_QPC_MODIFY);
    qpc_body.modify_wbe[0] = 8'h1;
    expect_light_failure("QPC_STATE_REJECTS_PAIR", RDMA_OP_QPC_MODIFY,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("state_with_data", RDMA_OP_QPC_MODIFY);
    qpc_body.modify_data[0] = 64'h1;
    expect_light_failure("QPC_STATE_REJECTS_DATA", RDMA_OP_QPC_MODIFY,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("state_with_buffer", RDMA_OP_QPC_MODIFY);
    qpc_body.qpc_buffer.value = 64'h1;
    expect_light_failure("QPC_STATE_REJECTS_BUFFER", RDMA_OP_QPC_MODIFY,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);

    qpc_body = make_qpc_body("delete_with_buffer", RDMA_OP_QPC_DELETE);
    qpc_body.qpc_buffer.value = 64'h200;
    expect_light_failure("QPC_DELETE_REJECTS_BUFFER", RDMA_OP_QPC_DELETE,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("delete_with_modify", RDMA_OP_QPC_DELETE);
    qpc_body.next_state = RDMA_QPS_RTS;
    qpc_body.wbe_template_count = 1;
    qpc_body.modify_wbe[0] = 1;
    qpc_body.modify_data[0] = 1;
    expect_light_failure("QPC_DELETE_REJECTS_MODIFY_FIELDS",
                         RDMA_OP_QPC_DELETE, qpc_body,
                         RDMA_SC_INVALID_ARGUMENT);

    qpc_body = make_qpc_body("query_with_cqs", RDMA_OP_QPC_QUERY);
    qpc_body.send_cq_h = make_handle("query_scq", RDMA_RESOURCE_CQ,
                                     21'h15555);
    qpc_body.recv_cq_h = make_handle("query_rcq", RDMA_RESOURCE_CQ,
                                     21'h0aaaa);
    expect_light_failure("QPC_QUERY_REJECTS_CQS", RDMA_OP_QPC_QUERY,
                         qpc_body, RDMA_SC_INVALID_ARGUMENT);
    qpc_body = make_qpc_body("query_with_modify", RDMA_OP_QPC_QUERY);
    qpc_body.next_state = RDMA_QPS_RTS;
    qpc_body.wbe_template_count = 1;
    qpc_body.modify_start_qword[0] = 1;
    qpc_body.modify_data[0] = 1;
    expect_light_failure("QPC_QUERY_REJECTS_MODIFY_FIELDS",
                         RDMA_OP_QPC_QUERY, qpc_body,
                         RDMA_SC_INVALID_ARGUMENT);

    qpc_body = make_qpc_body("mutually_exclusive_modify",
                             RDMA_OP_QPC_MODIFY,
                             RDMA_QPC_MODIFY_FULL);
    qpc_body.partial_modify = 1'b1;
    expect_light_failure("QPC_MODES_MUTUALLY_EXCLUSIVE",
                         RDMA_OP_QPC_MODIFY, qpc_body,
                         RDMA_SC_INVALID_ARGUMENT);
    wrong_model = make_object_body("wrong_qpc_model", RDMA_RESOURCE_QP,
                                   21'h12345);
    expect_light_failure("QPC_WRONG_MODEL", RDMA_OP_QPC_CREATE,
                         wrong_model, RDMA_SC_INVALID_ARGUMENT);
    expect_light_failure("LIGHT_UNSUPPORTED_OPCODE", 8'hff, null,
                         RDMA_SC_UNSUPPORTED_OPCODE);
  endfunction

  // 功能：在测试辅助 rdma_cmq_codec_test.check_occ_semantics 中构造或驱动“occ semantics”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_occ_semantics();
    rdma_hw_occ_flush_body occ_body;

    occ_body = rdma_hw_occ_flush_body::type_id::create("occ_empty");
    expect_light_failure("OCC_REJECTS_EMPTY", RDMA_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);

    occ_body = make_occ_vf("occ_vf_with_serial_selector");
    occ_body.mr_serial_flush = 1'b1;
    expect_light_failure("OCC_REJECTS_VF_SERIAL_SELECTORS",
                         RDMA_OP_OCC_FLUSH, occ_body,
                         RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_vf("occ_vf_missing_object");
    occ_body.qpc = 1'b0;
    expect_light_failure("OCC_VF_REQUIRES_OBJECTS", RDMA_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_vf("occ_vf_with_qpn");
    occ_body.qpn = 1;
    expect_light_failure("OCC_VF_REJECTS_QPN", RDMA_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_vf("occ_vf_with_serial");
    occ_body.mr_serial = 1;
    expect_light_failure("OCC_VF_REJECTS_SERIAL", RDMA_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_vf("occ_vf_with_backing");
    occ_body.pd_backing.value = 64'h1000;
    expect_light_failure("OCC_VF_REJECTS_BACKING", RDMA_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);

    occ_body = make_occ_serial("occ_serial_missing_pble");
    occ_body.pble = 1'b0;
    expect_light_failure("OCC_SERIAL_REQUIRES_PBLE", RDMA_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_serial("occ_serial_with_pd");
    occ_body.pd = 1'b1;
    occ_body.pd_backing.value = 64'h1000;
    expect_light_failure("OCC_REJECTS_SERIAL_PD_SELECTORS",
                         RDMA_OP_OCC_FLUSH, occ_body,
                         RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_serial("occ_serial_with_qpn");
    occ_body.qpn = 1;
    expect_light_failure("OCC_SERIAL_REJECTS_QPN", RDMA_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);

    occ_body = make_occ_qpn("occ_qpn_missing_object");
    occ_body.eirqe = 1'b0;
    expect_light_failure("OCC_QPN_REQUIRES_OBJECTS", RDMA_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_qpn("occ_qpn_extra_object");
    occ_body.qpc = 1'b1;
    expect_light_failure("OCC_QPN_REJECTS_EXTRA_OBJECT",
                         RDMA_OP_OCC_FLUSH, occ_body,
                         RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_qpn("occ_qpn_with_serial");
    occ_body.mr_serial = 1;
    expect_light_failure("OCC_QPN_REJECTS_SERIAL", RDMA_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_qpn("occ_qpn_with_backing");
    occ_body.pd_backing.value = 64'h1000;
    expect_light_failure("OCC_QPN_REJECTS_BACKING", RDMA_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);

    occ_body = make_occ_qpn_pd("occ_qpn_pd_without_backing");
    occ_body.pd_backing.value = 0;
    expect_light_failure("OCC_QPN_PD_REQUIRES_BACKING",
                         RDMA_OP_OCC_FLUSH, occ_body,
                         RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_qpn_pd("occ_qpn_pd_unaligned");
    occ_body.pd_backing.value |= 1;
    expect_light_failure("OCC_QPN_PD_REJECTS_UNALIGNED",
                         RDMA_OP_OCC_FLUSH, occ_body,
                         RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_qpn_pd("occ_qpn_pd_with_object");
    occ_body.eirqe = 1'b1;
    expect_light_failure("OCC_QPN_PD_REJECTS_OBJECT",
                         RDMA_OP_OCC_FLUSH, occ_body,
                         RDMA_SC_INVALID_ARGUMENT);

    occ_body = make_occ_pd("occ_pd_without_backing");
    occ_body.pd_backing.value = 0;
    expect_light_failure("OCC_PD_REQUIRES_BACKING", RDMA_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);
    occ_body = make_occ_pd("occ_pd_with_serial");
    occ_body.mr_serial = 1;
    expect_light_failure("OCC_PD_REJECTS_SERIAL", RDMA_OP_OCC_FLUSH,
                         occ_body, RDMA_SC_INVALID_ARGUMENT);
  endfunction

  // 功能：在测试辅助 rdma_cmq_codec_test.check_negatives 中构造或驱动“negatives”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_negatives();
    rdma_hw_qpc_command_body qpc_body;
    rdma_hw_image base;
    rdma_hw_image bad;
    rdma_hw_image empty_body;
    rdma_hw_image qpc_source;
    rdma_hw_cmq_envelope envelope;
    rdma_hw_cmq_test_bad_envelope_codec bad_envelope_codec;
    rdma_hw_cmq_request_composer bad_envelope_composer;
    rdma_hw_cmq_test_overlap_registry overlap_registry;
    rdma_image_kind_e ignored_kind;
    bit [63:0] masks[8];
    rdma_status status;

    qpc_body = make_qpc_body("negative_qpc_create",
                             RDMA_OP_QPC_CREATE);
    base = encode_light("NEGATIVE_BASE", RDMA_OP_QPC_CREATE, qpc_body);
    qpc_source = make_qpc_signature_source();
    envelope = make_envelope(RDMA_OP_QPC_CREATE);

    bad = clone_image(base, "BAD_KIND_CLONE");
    bad.image_kind = RDMA_IMAGE_CQC;
    expect_compose_failure("BODY_KIND", composer, envelope, bad, qpc_source,
                           RDMA_SC_CODEC_ERROR);
    bad = clone_image(base, "BAD_VERSION_CLONE");
    bad.hardware_version++;
    expect_compose_failure("BODY_VERSION", composer, envelope, bad,
                           qpc_source, RDMA_SC_CODEC_ERROR);
    bad = clone_image(base, "BAD_ENDIAN_CLONE");
    bad.endian = RDMA_ENDIAN_LITTLE;
    expect_compose_failure("BODY_ENDIAN", composer, envelope, bad,
                           qpc_source, RDMA_SC_CODEC_ERROR);
    bad = clone_image(base, "BAD_LENGTH_CLONE");
    bad.length = 63;
    expect_compose_failure("BODY_LENGTH", composer, envelope, bad,
                           qpc_source, RDMA_SC_CODEC_ERROR);
    bad = clone_image(base, "BAD_ALIGNMENT_CLONE");
    bad.alignment = 8;
    expect_compose_failure("BODY_ALIGNMENT", composer, envelope, bad,
                           qpc_source, RDMA_SC_CODEC_ERROR);

    bad = clone_image(base, "BAD_RESERVED_CLONE");
    set_image_word(bad, 7, image_word(bad, 7) | 64'h1);
    expect_compose_failure("BODY_OUTSIDE_MASK", composer, envelope, bad,
                           qpc_source, RDMA_SC_CODEC_ERROR);

    envelope = make_envelope(RDMA_OP_QPC_DELETE);
    expect_compose_failure("OPCODE_BODY_PAIRING", composer, envelope, base,
                           null, RDMA_SC_CODEC_ERROR);

    status = light.encode(RDMA_OP_TQ_FLUSH, null, empty_body);
    expect_ok("NEG_EMPTY_BODY", status);
    envelope = make_envelope(8'hff);
    expect_compose_failure("UNREGISTERED_OPCODE", composer, envelope,
                           empty_body, null, RDMA_SC_UNSUPPORTED_OPCODE);
    envelope = make_envelope(RDMA_OP_QP_FLUSH);
    expect_compose_failure("QP_FLUSH_UNREGISTERED", composer, envelope,
                           empty_body, null, RDMA_SC_UNSUPPORTED_OPCODE);
    envelope = make_envelope(8'h11);
    expect_compose_failure("CEQC_MODIFY_UNREGISTERED", composer, envelope,
                           empty_body, null, RDMA_SC_UNSUPPORTED_OPCODE);
    envelope = make_envelope(8'h15);
    expect_compose_failure("AEQC_MODIFY_UNREGISTERED", composer, envelope,
                           empty_body, null, RDMA_SC_UNSUPPORTED_OPCODE);
    envelope = make_envelope(8'h36);
    expect_compose_failure("SRFQC_MODIFY_UNREGISTERED", composer, envelope,
                           empty_body, null, RDMA_SC_UNSUPPORTED_OPCODE);

    bad_envelope_codec = new("bad_envelope_codec");
    bad_envelope_composer = new("bad_envelope_composer", ownership,
                                bad_envelope_codec);
    envelope = make_envelope(RDMA_OP_TQ_FLUSH);
    expect_compose_failure("ENVELOPE_OUTSIDE_MASK", bad_envelope_composer,
                           envelope, empty_body, null, RDMA_SC_CODEC_ERROR);

    for (int unsigned attack = RDMA_CMQ_TEST_ENVELOPE_VALID;
         attack <= RDMA_CMQ_TEST_ENVELOPE_MUTATE_INPUT; attack++) begin
      rdma_hw_cmq_test_envelope_attack_e selected_attack;
      string label;
      if (!$cast(selected_attack, attack))
        `uvm_fatal("ENVELOPE_ATTACK_CAST", "invalid test attack")
      label = $sformatf("ENVELOPE_ATTACK_%0d", attack);
      bad_envelope_codec = new({label, "_codec"}, selected_attack);
      bad_envelope_composer = new({label, "_composer"}, ownership,
                                  bad_envelope_codec);
      status = bad_envelope_composer.build_body(RDMA_OP_TQ_FLUSH, null,
                                                empty_body);
      expect_ok({label, "_BODY"}, status);
      envelope = make_envelope(RDMA_OP_TQ_FLUSH);
      expect_compose_failure(label, bad_envelope_composer, envelope,
                             empty_body, null, RDMA_SC_CODEC_ERROR);
    end

    status = composer.build_body(RDMA_OP_TQ_FLUSH, null, empty_body);
    expect_ok("NULL_ENVELOPE_BODY", status);
    expect_compose_failure("NULL_ENVELOPE", composer, null, empty_body,
                           null, RDMA_SC_CODEC_ERROR);

    overlap_registry = new("overlap_registry");
    foreach (masks[i]) masks[i] = '0;
    masks[0] = 64'h8000_0000_0000_0000;
    status = overlap_registry.register_body(8'hfe, RDMA_IMAGE_CMQ_SQE,
                                            masks);
    expect_status("REGISTER_OVERLAP_REJECTED", status,
                  RDMA_SC_CODEC_ERROR);

    bad = clone_image(qpc_source, "BAD_QPC_KIND");
    bad.image_kind = RDMA_IMAGE_CMQ_SQE;
    envelope = make_envelope(RDMA_OP_QPC_CREATE);
    expect_compose_failure("QPC_SIGNATURE_SOURCE_KIND", composer, envelope,
                           base, bad, RDMA_SC_CODEC_ERROR);
    bad = clone_image(qpc_source, "STALE_QPC_GENERATION");
    bad.function_generation++;
    expect_compose_failure("QPC_SIGNATURE_SOURCE_GENERATION", composer,
                           envelope, base, bad, RDMA_SC_CODEC_ERROR);
    bad = clone_image(qpc_source, "RESERVED_QPC_SIGNATURE_SOURCE");
    // qword63 bit0 是 wr.h 明确声明的 SQ_PI[0] runtime shadow，不能再用作
    // reserved 负向向量；bit47 不在四段 readback mask 内，仍代表未知硬件位。
    set_image_word(bad, 63, image_word(bad, 63) | (64'h1 << 47));
    expect_compose_failure("QPC_SIGNATURE_SOURCE_RESERVED", composer,
                           envelope, base, bad, RDMA_SC_CODEC_ERROR);
    bad = make_qpc_signature_source(21'h12346);
    expect_compose_failure("QPC_SIGNATURE_SOURCE_QPN", composer, envelope,
                           base, bad, RDMA_SC_CODEC_ERROR);
    bad = clone_image(base, "NONZERO_SIGNATURE_BODY");
    set_image_word(bad, 1, image_word(bad, 1) |
                   (64'h5a << RDMA_CMQ_SIGNATURE_LSB));
    expect_compose_failure("NONZERO_SOURCE_SIGNATURE", composer, envelope,
                           bad, qpc_source, RDMA_SC_CODEC_ERROR);
  endfunction

  // 功能：在测试辅助 rdma_cmq_codec_test.check_registry_contract 中构造或驱动“registry contract”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_registry_contract();
    rdma_hw_cmq_body_registry registry;
    rdma_hw_cmq_body_registry replacement;
    rdma_hw_cmq_body_registry validated_snapshot;
    rdma_hw_cmq_test_overlap_registry invalid_source;
    rdma_hw_cmq_duplicate_catcher catcher;
    rdma_status status;
    rdma_image_kind_e kind;
    bit [63:0] masks[8];
    bit [63:0] duplicate_masks[8];
    bit [63:0] replacement_masks[8];

    registry = rdma_hw_cmq_body_registry::type_id::create(
      "contract_registry");
    foreach (masks[i]) masks[i] = '0;
    masks[0] = 64'h1;
    status = registry.register_body(8'hee, RDMA_IMAGE_CMQ_SQE, masks);
    expect_ok("REGISTRY_FIRST", status);
    catcher = new("cmq_duplicate_catcher");
    uvm_report_cb::add(null, catcher);
    foreach (duplicate_masks[i]) duplicate_masks[i] = masks[i];
    duplicate_masks[0] |= request_envelope_mask(0);
    status = registry.register_body(8'hee, RDMA_IMAGE_CMQ_SQE,
                                    duplicate_masks);
    uvm_report_cb::delete(null, catcher);
    expect_status("REGISTRY_DUPLICATE", status, RDMA_SC_INVALID_STATE);
    if (!catcher.caught)
      `uvm_error("REGISTRY_DUPLICATE", "duplicate fatal was not reported")
    registry.seal();
    status = registry.register_body(8'hef, RDMA_IMAGE_CMQ_SQE, masks);
    expect_status("REGISTRY_SEALED", status, RDMA_SC_INVALID_STATE);
    status = registry.lookup(8'hee, kind, masks);
    expect_ok("REGISTRY_LOOKUP", status);
    if (kind != RDMA_IMAGE_CMQ_SQE || masks[0] != 64'h1)
      `uvm_error("REGISTRY_LOOKUP", "registered identity was not retained")
    status = registry.lookup(8'hef, kind, masks);
    expect_status("REGISTRY_MISSING", status, RDMA_SC_UNSUPPORTED_OPCODE);

    replacement = rdma_hw_cmq_body_registry::type_id::create(
      "contract_replacement_registry");
    foreach (replacement_masks[i]) replacement_masks[i] = '0;
    replacement_masks[1] = 64'h2;
    status = replacement.register_body(8'hef, RDMA_IMAGE_CMQ_SQE,
                                       replacement_masks);
    expect_ok("REGISTRY_REPLACEMENT_REGISTER", status);
    registry.copy(replacement);
    status = registry.lookup(8'hee, kind, masks);
    expect_ok("SEALED_COPY_RETAINS_ORIGINAL", status);
    if (kind != RDMA_IMAGE_CMQ_SQE || masks[0] != 64'h1)
      `uvm_error("SEALED_COPY_RETAINS_ORIGINAL",
                 "sealed registry entry changed after copy")
    status = registry.lookup(8'hef, kind, masks);
    expect_status("SEALED_COPY_REJECTS_REPLACEMENT", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);
    status = registry.register_body(8'hf0, RDMA_IMAGE_CMQ_SQE,
                                    replacement_masks);
    expect_status("SEALED_COPY_RETAINS_SEAL", status,
                  RDMA_SC_INVALID_STATE);

    status = replacement.validated_snapshot(validated_snapshot);
    expect_ok("VALIDATED_SNAPSHOT", status);
    if (validated_snapshot == null)
      `uvm_error("VALIDATED_SNAPSHOT", "snapshot was not published")
    else begin
      status = validated_snapshot.lookup(8'hef, kind, masks);
      expect_ok("VALIDATED_SNAPSHOT_LOOKUP", status);
      status = validated_snapshot.register_body(8'hf1, RDMA_IMAGE_CMQ_SQE,
                                                replacement_masks);
      expect_status("VALIDATED_SNAPSHOT_SEALED", status,
                    RDMA_SC_INVALID_STATE);
    end

    invalid_source = new("invalid_snapshot_source");
    foreach (replacement_masks[i]) replacement_masks[i] = '0;
    replacement_masks[0] = request_envelope_mask(0);
    invalid_source.force_body(8'hf2, RDMA_IMAGE_CMQ_SQE,
                              replacement_masks);
    status = invalid_source.validated_snapshot(validated_snapshot);
    expect_status("VALIDATED_SNAPSHOT_REVALIDATES", status,
                  RDMA_SC_CODEC_ERROR);
    if (validated_snapshot != null)
      `uvm_error("VALIDATED_SNAPSHOT_REVALIDATES",
                 "invalid source published a snapshot")
  endfunction

  // 功能：check_driver_034_opcode_registry 校验 0.1.34 驱动新增 CMQ opcode
  //   已被统一 registry 收录，并验证描述符长度、掩码和错误映射可查询。
  // 输入/输出及副作用：无显式输入；函数只读取静态 registry 并在发现漂移时
  //   报告 UVM_ERROR，不修改 CMQ ring 或任何运行期资源。
  // 失败/边界：任一 opcode 缺失、描述符非法、请求/响应长度不是 64 字节，或
  //   未知 opcode 被错误接受，都会报告错误；失败路径不提交部分状态。
  function automatic void check_driver_034_opcode_registry();
    bit [7:0] new_opcodes[] = '{
      8'h07, 8'h08, 8'h09, 8'h0b, 8'h0d, 8'h11,
      8'h15, 8'h18, 8'h19, 8'h1b, 8'h1c, 8'h1d,
      8'h1e, 8'h1f, 8'h21, 8'h22, 8'h23, 8'h24,
      8'h25, 8'h26, 8'h27, 8'h28, 8'h29, 8'h2a,
      8'h2b, 8'h2c, 8'h2d, 8'h2e, 8'h2f, 8'h30,
      8'h31, 8'h32, 8'h33, 8'h34, 8'h36, 8'h39,
      8'h3a, 8'h3b, 8'h3c, 8'h3d, 8'h3e, 8'h3f,
      8'h40, 8'h41, 8'h42, 8'h43, 8'h44, 8'h46,
      8'h47, 8'h48
    };
    bit [7:0] request_opcodes[] = '{
      RDMA_OP_QPC_CREATE, RDMA_OP_QPC_MODIFY,
      RDMA_OP_QPC_DELETE, RDMA_OP_QPC_QUERY,
      RDMA_OP_KEY_ALLOC, RDMA_OP_MR_REGISTER,
      RDMA_OP_MR_DEREGISTER, RDMA_OP_OCC_FLUSH,
      RDMA_OP_CQC_CREATE, RDMA_OP_CQC_DELETE,
      RDMA_OP_CQC_QUERY, RDMA_OP_CEQC_CREATE,
      RDMA_OP_CEQC_DELETE, RDMA_OP_CEQC_QUERY,
      RDMA_OP_AEQC_CREATE, RDMA_OP_AEQC_DELETE,
      RDMA_OP_AEQC_QUERY, RDMA_OP_TQ_FLUSH,
      RDMA_OP_SRFQC_CREATE, RDMA_OP_SRFQC_DELETE,
      RDMA_OP_SRFQC_QUERY
    };
    rdma_cmq_opcode_descriptor descriptor;
    rdma_status status;
    bit [7:0] listed_request_opcodes[$];

    rdma_cmq_codec_registry::list_request_supported(listed_request_opcodes);
    if (listed_request_opcodes.size() != request_opcodes.size())
      `uvm_error("CMQ_REQUEST_CAPABILITY",
                 $sformatf("expected %0d request encoders, got %0d",
                           request_opcodes.size(),
                           listed_request_opcodes.size()))
    foreach (request_opcodes[i]) begin
      if (i >= listed_request_opcodes.size() ||
          listed_request_opcodes[i] != request_opcodes[i])
        `uvm_error("CMQ_REQUEST_CAPABILITY",
                   $sformatf("request encoder list mismatch at index %0d",
                             i))
    end

    foreach (new_opcodes[i]) begin
      if (!rdma_cmq_codec_registry::is_supported(new_opcodes[i]))
        `uvm_error("CMQ_REGISTRY_034",
                   $sformatf("missing driver 0.1.34 opcode 0x%02x",
                             new_opcodes[i]))
      status = rdma_cmq_codec_registry::lookup(new_opcodes[i], descriptor);
      expect_ok($sformatf("CMQ_DESC_034_%02x", new_opcodes[i]), status);
      if (descriptor == null)
        continue;
      if (descriptor.request_bytes != RDMA_CMQE_BYTES ||
          descriptor.response_bytes != RDMA_CMQE_BYTES ||
          !descriptor.response_allowed ||
          !descriptor.valid())
        `uvm_error("CMQ_REGISTRY_034",
                   $sformatf("invalid descriptor for opcode 0x%02x",
                             new_opcodes[i]))
    end

    foreach (request_opcodes[i]) begin
      if (!rdma_cmq_codec_registry::is_request_supported(
            request_opcodes[i]))
        `uvm_error("CMQ_REQUEST_CAPABILITY",
                   $sformatf("body encoder opcode 0x%02x is not request-supported",
                             request_opcodes[i]))
      status = rdma_cmq_codec_registry::lookup(request_opcodes[i],
                                                descriptor);
      expect_ok($sformatf("CMQ_REQUEST_DESC_%02x", request_opcodes[i]),
                status);
      if (descriptor != null && !descriptor.request_allowed)
        `uvm_error("CMQ_REQUEST_CAPABILITY",
                   $sformatf("body encoder opcode 0x%02x is denied",
                             request_opcodes[i]))
    end

    // OCC_FLUSH 与 TQ_FLUSH 的 body 在驱动 ABI 中不携带 Function
    // generation；generation 只保留在最终定址 SQE 的 authority metadata。
    // 直接检查 registry，避免 compose/profile 的补偿分支掩盖静态表遗漏。
    if (!rdma_cmq_codec_registry::is_generationless(RDMA_OP_OCC_FLUSH))
      `uvm_error("CMQ_GENERATIONLESS_REGISTRY",
                 "OCC_FLUSH must be generationless in the opcode registry")
    if (!rdma_cmq_codec_registry::is_generationless(RDMA_OP_TQ_FLUSH))
      `uvm_error("CMQ_GENERATIONLESS_REGISTRY",
                 "TQ_FLUSH must be generationless in the opcode registry")

    status = rdma_cmq_codec_registry::lookup(RDMA_OP_IFA_UPDATE,
                                             descriptor);
    expect_ok("CMQ_IFA_UPDATE_RESPONSE_ONLY", status);
    if (descriptor != null && descriptor.request_allowed)
      `uvm_error("CMQ_REQUEST_CAPABILITY",
                 "IFA_UPDATE has no body encoder but is request-supported")
    if (rdma_cmq_codec_registry::is_request_supported(RDMA_OP_IFA_UPDATE))
      `uvm_error("CMQ_REQUEST_CAPABILITY",
                 "IFA_UPDATE incorrectly appears in request capability")

    begin
      rdma_hw_image unsupported_body;
      rdma_hw_image forged_body;
      rdma_hw_image forged_result;
      rdma_hw_cmq_envelope response_only_envelope;
      unsupported_body = null;
      status = composer.build_body(RDMA_OP_IFA_UPDATE, null,
                                   unsupported_body);
      expect_status("CMQ_IFA_UPDATE_BUILD_REJECTED", status,
                    RDMA_SC_UNSUPPORTED_OPCODE);
      if (status != null &&
          status.message !=
            "CMQ request opcode 0x39 has no body encoder")
        `uvm_error("CMQ_REQUEST_CAPABILITY",
                   {"unexpected response-only rejection: ",
                    status.message})
      if (unsupported_body != null)
        `uvm_error("CMQ_REQUEST_CAPABILITY",
                   "response-only build published a body image")

      forged_body = null;
      status = composer.build_body(RDMA_OP_TQ_FLUSH, null, forged_body);
      expect_ok("CMQ_FORGED_RESPONSE_ONLY_BODY", status);
      response_only_envelope = make_envelope(RDMA_OP_IFA_UPDATE);
      forged_result = null;
      status = composer.compose_request(response_only_envelope, forged_body,
                                        null, forged_result);
      expect_status("CMQ_RESPONSE_ONLY_COMPOSE_REJECTED", status,
                    RDMA_SC_UNSUPPORTED_OPCODE);
      if (forged_result != null)
        `uvm_error("CMQ_REQUEST_CAPABILITY",
                   "response-only opcode accepted a forged body")
    end

    if (rdma_cmq_codec_registry::is_supported(8'hff))
      `uvm_error("CMQ_REGISTRY_UNKNOWN", "unknown opcode 0xff was accepted")
    status = rdma_cmq_codec_registry::lookup(8'hff, descriptor);
    expect_status("CMQ_REGISTRY_UNKNOWN_STATUS", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);
    if (descriptor != null)
      `uvm_error("CMQ_REGISTRY_UNKNOWN_STATUS",
                 "unknown opcode returned a descriptor")
  endfunction

  // 功能：check_driver_034_golden_vectors 读取 0.1.34 CMQ 请求向量，并用
  //   descriptor 的 request mask 独立检查 opcode 与字段所有权。
  // 输入/输出及副作用：只读取 tests/data 下的不可变文本，不修改 codec、
  //   body registry 或 ring；解析失败通过 UVM_ERROR 报告。
  // 失败/边界：每个新增 opcode 必须恰好一条 64B 向量，byte3 必须等于
  //   literal opcode，且 payload 不得写入 envelope/body 未声明的位。
  function automatic void check_driver_034_golden_vectors();
    bit [7:0] expected_opcodes[] = '{
      8'h07, 8'h08, 8'h09, 8'h0b, 8'h0d, 8'h11, 8'h15, 8'h18,
      8'h19, 8'h1b, 8'h1c, 8'h1d, 8'h1e, 8'h1f, 8'h21, 8'h22,
      8'h23, 8'h24, 8'h25, 8'h26, 8'h27, 8'h28, 8'h29, 8'h2a,
      8'h2b, 8'h2c, 8'h2d, 8'h2e, 8'h2f, 8'h30, 8'h31, 8'h32,
      8'h33, 8'h34, 8'h36, 8'h39, 8'h3a, 8'h3b, 8'h3c, 8'h3d,
      8'h3e, 8'h3f, 8'h40, 8'h41, 8'h42, 8'h43, 8'h44, 8'h46,
      8'h47, 8'h48
    };
    rdma_golden_case cases[$];
    string error;
    if (!rdma_golden_reader::read_all(
          "../tests/data/rdma_0_1_34_cmq_vectors.hex", cases, error)) begin
      `uvm_error("CMQ034_GOLDEN_READ", error)
      return;
    end
    if (cases.size() != expected_opcodes.size()) begin
      `uvm_error("CMQ034_GOLDEN_COUNT",
                 $sformatf("expected %0d vectors, got %0d",
                           expected_opcodes.size(), cases.size()))
      return;
    end
    foreach (cases[i]) begin
      rdma_cmq_opcode_descriptor descriptor;
      bit [63:0] word;
      rdma_status status;
      if (cases[i].byte_count != RDMA_CMQE_BYTES ||
          cases[i].payload.size() != RDMA_CMQE_BYTES)
        `uvm_error("CMQ034_GOLDEN_SIZE", $sformatf(
          "%s is not a 64B vector", cases[i].name))
      if (cases[i].payload.size() > 3 &&
          cases[i].payload[3] != expected_opcodes[i])
        `uvm_error("CMQ034_GOLDEN_OPCODE", $sformatf(
          "%s byte3=0x%02x expected=0x%02x", cases[i].name,
          cases[i].payload[3], expected_opcodes[i]))
      status = rdma_cmq_codec_registry::lookup(expected_opcodes[i],
                                                descriptor);
      expect_ok($sformatf("CMQ034_GOLDEN_DESC_%02x", expected_opcodes[i]),
                status);
      if (descriptor == null) continue;
      for (int unsigned q = 0; q < 8; q++) begin
        word = '0;
        for (int unsigned b = 0; b < 8; b++)
          word[63 - b * 8 -: 8] = cases[i].payload[q * 8 + b];
        if ((word & ~(request_envelope_mask(q) |
                      descriptor.request_qword_masks[q])) != 0)
          `uvm_error("CMQ034_GOLDEN_MASK", $sformatf(
            "%s writes outside descriptor mask at qword %0d",
            cases[i].name, q))
      end
    end
  endfunction

  // 功能：check_cqc_raw_word_baseline 将 CQC_CREATE 编码镜像导入
  // rdma_hw_qword_builder，冻结 cq.h:123-153 所定义的八个逻辑 qword 坐标。
  // 输入/输出及副作用：使用本地 CQC fixture、builder 和 image；get_words 输出
  // detached qword 快照，仅产生 UVM 断言，不修改生产 codec 或 registry 所有权。
  // 失败/边界：编码失败、镜像长度非 64B、builder 写入失败，或任一 qword 超出
  // driver body_mask 均报告错误；不接受缺失字段被默认为零的情况。
  function automatic void check_cqc_raw_word_baseline();
    rdma_hw_image image;
    rdma_cqc_model cqc;
    rdma_hw_qword_builder builder;
    bit [63:0] words[];
    bit [63:0] mask;
    rdma_status status;

    cqc = make_cqc();
    image = encode_context("CQC_RAW_BASELINE", RDMA_OP_CQC_CREATE, cqc);
    if (image == null || image.bytes.size() != RDMA_CMQE_BYTES) begin
      `uvm_error("CQC_RAW_BASELINE", "CQC image is not a complete 64B body")
      return;
    end
    builder = rdma_hw_qword_builder::type_id::create("cqc_raw_builder");
    status = builder.reset(RDMA_CMQE_BYTES);
    expect_ok("CQC_RAW_BUILDER_RESET", status);
    status = builder.put_memcpy(0, image.bytes);
    expect_ok("CQC_RAW_BUILDER_COPY", status);
    builder.get_words(words);
    if (words.size() != 8) begin
      `uvm_error("CQC_RAW_BASELINE", "builder did not return eight qwords")
      return;
    end
    for (int unsigned q = 0; q < 8; q++) begin
      if (!body_mask(RDMA_IMAGE_CQC, RDMA_OP_CQC_CREATE, 0, q, mask))
        `uvm_error("CQC_RAW_MASK", $sformatf(
          "driver mask missing for CQC qword %0d", q))
      else if ((words[q] & ~mask) != 0)
        `uvm_error("CQC_RAW_MASK", $sformatf(
          "CQC qword %0d writes outside driver mask: %016x", q,
          words[q] & ~mask))
    end
    // 关键字段的原始坐标证据：PI/wrap、CQE size、CI/wrap、arm、shadow PA、CEQN。
    if (words[4][22:0] != 23'd17 || words[4][23] != 1'b1)
      `uvm_error("CQC_RAW_PI", "CQ PI/wrap raw coordinate mismatch")
    if (words[4][63:62] != 2'd1)
      `uvm_error("CQC_RAW_CQE_SIZE", "CQE size code is not at qword4[63:62]")
    if (words[1][60:56] != 5'd10 || words[1][63:62] != 2'd1)
      `uvm_error("CQC_RAW_STATE_SIZE", "CQ size/state raw coordinate mismatch")
    if (words[5][11:0] != 12'h234)
      `uvm_error("CQC_RAW_CEQN", "CEQN raw coordinate mismatch")
    if (words[6][63:6] != (64'h0000_0000_0300_0040 >> 6))
      `uvm_error("CQC_RAW_SHADOW", "shadow PA raw coordinate mismatch")
    if (words[7][22:0] != 23'd9 || words[7][23] != 1'b0)
      `uvm_error("CQC_RAW_CI", "CQ CI/wrap raw coordinate mismatch")
    if (words[7][35:32] != 4'b10_01)
      `uvm_error("CQC_RAW_ARM", "arm fields raw coordinate mismatch")
  endfunction

  // 功能：在测试辅助 rdma_cmq_codec_test.check_injected_registry_snapshot 中构造或驱动“injected registry snapshot”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_injected_registry_snapshot();
    rdma_hw_cmq_body_registry injected;
    rdma_hw_cmq_body_registry replacement;
    rdma_hw_cmq_request_composer snapshot_composer;
    rdma_hw_cmq_envelope envelope;
    rdma_hw_image empty_body;
    rdma_hw_image result;
    bit [63:0] masks[8];
    rdma_status status;

    injected = rdma_hw_cmq_body_registry::type_id::create(
      "snapshot_injected_registry");
    replacement = rdma_hw_cmq_body_registry::type_id::create(
      "snapshot_replacement_registry");
    foreach (masks[i]) masks[i] = '0;
    status = injected.register_body(RDMA_OP_TQ_FLUSH,
                                    RDMA_IMAGE_CMQ_SQE, masks);
    expect_ok("SNAPSHOT_REGISTER_ORIGINAL", status);
    injected.seal();
    snapshot_composer = new("snapshot_composer", injected);

    status = replacement.register_body(8'he1, RDMA_IMAGE_CMQ_SQE, masks);
    expect_ok("SNAPSHOT_REGISTER_REPLACEMENT", status);
    injected.copy(replacement);

    status = snapshot_composer.build_body(RDMA_OP_TQ_FLUSH, null,
                                          empty_body);
    expect_ok("SNAPSHOT_EMPTY_BODY", status);
    envelope = make_envelope(RDMA_OP_TQ_FLUSH);
    result = rdma_hw_image::type_id::create("snapshot_sentinel");
    status = snapshot_composer.compose_request(envelope, empty_body, null,
                                               result);
    expect_ok("SNAPSHOT_COMPOSE_ORIGINAL", status);
    if (result == null)
      `uvm_error("SNAPSHOT_COMPOSE_ORIGINAL",
                 "composer did not preserve injected ownership snapshot")
  endfunction

  // 功能：在 rdma_cmq_codec_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    rdma_status status;

    phase.raise_objection(this);
    ownership = rdma_hw_cmq_body_registry::type_id::create(
      "cmq_ownership");
    status = rdma_register_cmq_request_bodies(ownership);
    expect_ok("OWNERSHIP_REGISTER", status);
    ownership.seal();
    light = rdma_hw_cmq_light_body_codec::type_id::create(
      "cmq_light_codec");
    composer = new("cmq_composer", ownership);
    context_registry = rdma_codec_registry::type_id::create(
      "cmq_context_registry");
    status = rdma_register_context_body_codecs(context_registry);
    expect_ok("CONTEXT_REGISTER", status);
    qpc_registry = rdma_codec_registry::type_id::create("cmq_qpc_registry");
    status = rdma_register_qpc_codecs(qpc_registry);
    expect_ok("QPC_REGISTER", status);

    check_registry_contract();
    check_driver_034_opcode_registry();
    check_driver_034_golden_vectors();
    check_driver_body_mask_contracts();
    check_cqc_raw_word_baseline();
    check_injected_registry_snapshot();
    check_envelope_oracle();
    check_ownership_oracles();
    check_provenance_cross_pairs();
    check_artifact_contract();
    check_artifact_lifecycle();
    check_qpc_light_semantics();
    check_occ_semantics();
    check_all_supported();
    check_qpc_full_modify_templates();
    check_negatives();
    phase.drop_objection(this);
  endtask
endclass
