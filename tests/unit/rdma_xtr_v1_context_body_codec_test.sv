// 目录：测试层 unit/rdma_xtr_v1_context_body_codec_test.sv。
// 职责：验证 rdma_xtr_v1_context_body_codec_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_xtr_v1_context_body_codec_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_xtr_v1_context_body_codec_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_context_body_codec_test)

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_xtr_v1_context_body_codec_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：执行接口 expect_status 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 expect_status）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：执行接口 expect_ok 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 expect_ok）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void expect_ok(string label, rdma_status status);
    expect_status(label, status, RDMA_SC_OK);
  endfunction

  // 功能：依据输入快照构造请求、资源或适配对象，并返回独立的结果载体（接口 make_handle）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic rdma_handle make_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id,
    longint unsigned function_uid = 64'h1122_3344_5566_7788,
    int unsigned generation = 9
  );
    rdma_handle handle;
    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.object_id = object_id;
    handle.function_uid = function_uid;
    handle.generation = generation;
    return handle;
  endfunction

  // 功能：依据输入快照构造请求、资源或适配对象，并返回独立的结果载体（接口 make_boundary_page_layout）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic rdma_page_table_layout make_boundary_page_layout(
    string name,
    rdma_object_mode_e mode
  );
    rdma_page_table_layout layout;
    layout = rdma_page_table_layout::type_id::create(name);
    layout.mode = mode;
    layout.sd_base.value = 64'hffff_ffff_ffff_f000;
    layout.current_base.value = 64'hffff_ffff_ffff_f000;
    layout.current_valid = 1'b1;
    layout.next_base.value = 64'hffff_ffff_ffff_f000;
    layout.next_valid = 1'b1;
    return layout;
  endfunction

  // 功能：依据输入快照构造请求、资源或适配对象，并返回独立的结果载体（接口 make_ring）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：依据输入快照构造请求、资源或适配对象，并返回独立的结果载体（接口 make_cqc）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic rdma_cqc_model make_cqc(string name = "cqc_boundary");
    rdma_cqc_model cqc;
    cqc = rdma_cqc_model::type_id::create(name);
    cqc.cq_h = make_handle({name, "_cq"}, RDMA_RESOURCE_CQ, 21'h1f_ffff);
    cqc.ceq_h = make_handle({name, "_ceq"}, RDMA_RESOURCE_CEQ, 12'hfff);
    cqc.state = RDMA_CONTEXT_ERROR;
    cqc.depth = 32'h8000_0000;
    cqc.cqe_size_bytes = 128;
    cqc.threshold = 7;
    cqc.page_layout = make_boundary_page_layout({name, "_layout"},
                                                RDMA_OBJECT_L3_INDIRECT_4K);
    cqc.producer = make_ring({name, "_producer"}, 23'h7f_ffff, 1'b1);
    cqc.consumer = make_ring({name, "_consumer"}, 23'h7f_ffff, 1'b1);
    cqc.urc_enable = 1'b1;
    cqc.load_ci_done = 1'b1;
    cqc.last_arm_sequence = 2'd3;
    cqc.arm_sequence = 2'd3;
    cqc.arm_state = 2'd2;
    cqc.shadow_backing.value = 64'hffff_ffff_ffff_ffc0;
    return cqc;
  endfunction

  // 功能：依据输入快照构造请求、资源或适配对象，并返回独立的结果载体（接口 make_mrt）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic rdma_mrt_model make_mrt(
    string name,
    rdma_mr_pbl_mode_e pbl_mode
  );
    rdma_mrt_model mrt;
    mrt = rdma_mrt_model::type_id::create(name);
    mrt.mr_h = make_handle({name, "_mr"}, RDMA_RESOURCE_MR, 24'hff_ffff);
    mrt.pd_h = make_handle({name, "_pd"}, RDMA_RESOURCE_PD, 16'hffff);
    mrt.state = RDMA_CONTEXT_VALID;
    mrt.iova.value = 64'hffff_ffff_ffff_ffff;
    mrt.length = 64'h0000_3fff_ffff_ffff;
    mrt.lkey = 32'hffff_ffff;
    mrt.rkey = mrt.lkey;
    mrt.access = '{local_write:1'b1, remote_read:1'b1,
                   remote_write:1'b1, memory_window_bind:1'b1,
                   remote_atomic:1'b1};
    mrt.object_type = 2'd2;
    mrt.page_layout.pbl_mode = pbl_mode;
    mrt.page_layout.host_page_size = RDMA_MR_PAGE_1G;
    mrt.page_layout.address_mode = RDMA_MR_ADDRESS_ZERO_BASED;
    mrt.page_layout.odp = 1'b1;
    mrt.page_layout.invalidate_enable = 1'b1;
    mrt.page_layout.payload_vf_enable = 1'b1;
    mrt.page_layout.payload_vf_id = 8'hff;
    mrt.page_layout.mr_serial = 12'hfff;
    case (pbl_mode)
      RDMA_MR_PBL0:
        mrt.page_layout.pba0.value = 64'hffff_ffff_ffff_f000;
      RDMA_MR_PBL1: begin
        mrt.page_layout.pba0.value = 64'hffff_ffff_ffff_f000;
        mrt.page_layout.pba1.value = 64'hffff_ffff_ffff_f000;
      end
      RDMA_MR_PBL2:
        mrt.page_layout.first_pbl_index = 28'hfff_ffff;
    endcase
    return mrt;
  endfunction

  // 功能：依据输入快照构造请求、资源或适配对象，并返回独立的结果载体（接口 make_srqc）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic rdma_srqc_model make_srqc(string name = "srqc_boundary");
    rdma_srqc_model srqc;
    srqc = rdma_srqc_model::type_id::create(name);
    srqc.srq_h = make_handle({name, "_srq"}, RDMA_RESOURCE_SRQ, 16'hffff);
    srqc.pd_h = make_handle({name, "_pd"}, RDMA_RESOURCE_PD, 16'hffff);
    srqc.state = RDMA_CONTEXT_ERROR;
    srqc.depth = 1 << 15;
    srqc.load_pi_threshold = 8'hff;
    srqc.limit_threshold = 14'h3fff;
    srqc.object_mode = RDMA_OBJECT_L3_INDIRECT_4K;
    srqc.srfq_backing.value = 64'hffff_ffff_ffff_f000;
    srqc.shadow_backing.value = 64'hffff_ffff_ffff_f000;
    srqc.producer = make_ring({name, "_producer"}, 15'h7fff, 1'b1);
    srqc.arm_sequence = 2'd3;
    return srqc;
  endfunction

  // 功能：依据输入快照构造请求、资源或适配对象，并返回独立的结果载体（接口 make_ceqc）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic rdma_ceqc_model make_ceqc(string name = "ceqc_boundary");
    rdma_ceqc_model ceqc;
    ceqc = rdma_ceqc_model::type_id::create(name);
    ceqc.ceq_h = make_handle({name, "_ceq"}, RDMA_RESOURCE_CEQ, 12'hfff);
    ceqc.state = RDMA_CONTEXT_ERROR;
    ceqc.depth = 32'h8000_0000;
    ceqc.vector_id = 16'hffff;
    ceqc.page_layout = make_boundary_page_layout({name, "_layout"},
                                                 RDMA_OBJECT_L3_INDIRECT_4K);
    ceqc.page_layout.sd_base = '0;
    ceqc.producer = make_ring({name, "_producer"}, 18'h3ffff, 1'b1);
    ceqc.consumer = make_ring({name, "_consumer"}, 18'h3ffff, 1'b1);
    return ceqc;
  endfunction

  // 功能：依据输入快照构造请求、资源或适配对象，并返回独立的结果载体（接口 make_aeqc）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic rdma_aeqc_model make_aeqc(string name = "aeqc_boundary");
    rdma_aeqc_model aeqc;
    aeqc = rdma_aeqc_model::type_id::create(name);
    aeqc.aeq_h = make_handle({name, "_aeq"}, RDMA_RESOURCE_AEQ, 12'hfff);
    aeqc.state = RDMA_CONTEXT_ERROR;
    aeqc.depth = 32'h8000_0000;
    aeqc.vector_id = 16'hffff;
    aeqc.page_layout = make_boundary_page_layout({name, "_layout"},
                                                 RDMA_OBJECT_L3_INDIRECT_4K);
    aeqc.page_layout.sd_base = '0;
    aeqc.producer = make_ring({name, "_producer"}, 18'h3ffff, 1'b1);
    aeqc.consumer = make_ring({name, "_consumer"}, 18'h3ffff, 1'b1);
    return aeqc;
  endfunction

  // 功能：执行接口 body_key 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 body_key）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic rdma_codec_key body_key(
    rdma_image_kind_e image_kind,
    string object_type,
    string variant,
    bit [7:0] opcode
  );
    rdma_codec_key key;
    key.hw_version = "xtr_v1";
    key.image_kind = image_kind;
    key.object_type = object_type;
    key.variant = variant;
    key.opcode = opcode;
    return key;
  endfunction

  // 功能：读取或查询当前对象的权威状态，并以返回值或 output 参数交付快照（接口 find_golden）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic rdma_xtr_v1_golden_case find_golden(
    rdma_xtr_v1_golden_case cases[$],
    string name
  );
    foreach (cases[i])
      if (cases[i].name == name)
        return cases[i];
    return null;
  endfunction

  // 功能：执行接口 require_golden 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 require_golden）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic rdma_xtr_v1_golden_case require_golden(
    rdma_xtr_v1_golden_case cases[$],
    string case_name
  );
    rdma_xtr_v1_golden_case golden;
    golden = find_golden(cases, case_name);
    if (golden == null) begin
      `uvm_error("BODY_GOLDEN_REQUIRED",
                 {"required golden case was not found: ", case_name})
      return null;
    end
    if (golden.payload.size() != 64) begin
      `uvm_error("BODY_GOLDEN_REQUIRED",
                 $sformatf("required golden case %s has %0d bytes", case_name,
                           golden.payload.size()))
      return null;
    end
    return golden;
  endfunction

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 clone_model）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic rdma_hw_model clone_model(
    rdma_hw_model source,
    string label
  );
    uvm_object cloned;
    rdma_hw_model copy;
    cloned = source.clone();
    if (cloned == null || !$cast(copy, cloned)) begin
      `uvm_error(label, "model clone failed")
      return null;
    end
    return copy;
  endfunction

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 clone_image）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：执行接口 image_word 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 image_word）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：执行接口 image_field 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 image_field）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：执行接口 expect_image_field 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 expect_image_field）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void expect_image_field(
    string label,
    rdma_hw_image image,
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width,
    bit [63:0] expected
  );
    bit [63:0] actual;
    if (image == null) begin
      `uvm_error(label, "cannot inspect a null image")
      return;
    end
    actual = image_field(image, word_byte_offset, lsb, width);
    if (actual != expected)
      `uvm_error(label,
                 $sformatf("got 0x%0x expected 0x%0x", actual, expected))
  endfunction

  // 功能：写入并校验运行所需的配置、身份或资源参数，建立后续操作的边界（接口 set_image_field）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void set_image_field(
    rdma_hw_image image,
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width,
    bit [63:0] value
  );
    bit [63:0] word;
    bit [63:0] width_mask;
    bit [63:0] field_mask;
    word = image_word(image, word_byte_offset >> 3);
    width_mask = (width == 64) ? '1 : ((64'h1 << width) - 1);
    field_mask = width_mask << lsb;
    word = (word & ~field_mask) | ((value << lsb) & field_mask);
    for (int unsigned i = 0; i < 8; i++)
      image.bytes[word_byte_offset + i] = word[63 - (i * 8) -: 8];
  endfunction

  // 功能：执行接口 expect_encode_failure 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 expect_encode_failure）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void expect_encode_failure(
    string label,
    rdma_codec_base codec,
    rdma_hw_model model
  );
    rdma_hw_image image;
    rdma_status status;
    image = rdma_hw_image::type_id::create({label, "_sentinel"});
    status = codec.encode(model, image);
    expect_status(label, status, RDMA_SC_INVALID_ARGUMENT);
    if (image != null)
      `uvm_error(label, "failed encode published an image")
  endfunction

  // 功能：执行接口 expect_decode_failure 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 expect_decode_failure）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void expect_decode_failure(
    string label,
    rdma_codec_base codec,
    rdma_hw_image image
  );
    rdma_hw_model model;
    rdma_status status;
    model = rdma_cqc_model::type_id::create({label, "_sentinel"});
    status = codec.decode(image, model);
    expect_status(label, status, RDMA_SC_CODEC_ERROR);
    if (model != null)
      `uvm_error(label, "failed decode published a model")
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_roundtrip_core）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_roundtrip_core(
    string label,
    rdma_codec_base codec,
    rdma_hw_model source,
    rdma_image_kind_e image_kind,
    int unsigned owner_generation,
    output rdma_hw_image image
  );
    rdma_status status;
    rdma_hw_model decoded;
    bit equal;
    string mismatch;
    image = null;
    status = codec.encode(source, image);
    expect_ok({label, "_ENCODE"}, status);
    if (image == null) begin
      `uvm_error(label, "successful encode published null")
      return;
    end
    if (image.length != 64 || image.bytes.size() != 64 ||
        image.alignment != 64 || image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != image_kind ||
        image.hardware_version != XTR_V1_HW_VERSION ||
        image.function_generation != owner_generation ||
        image.write_target_kind != RDMA_HW_TARGET_NONE ||
        image.backing_target.value != 0 || image.hmc_target.value != 0 ||
        image.bar_target.value != 0) begin
      `uvm_error(label, "encoded body metadata is not canonical")
    end
    for (int unsigned q = 0; q < 8; q++) begin
      if ((image_word(image, q) & request_envelope_mask(q)) != 0)
        `uvm_error(label, $sformatf("qword %0d writes request envelope", q))
    end
    decoded = null;
    status = codec.decode(image, decoded);
    expect_ok({label, "_DECODE"}, status);
    if (decoded == null) begin
      `uvm_error(label, "successful decode published null")
      return;
    end
    status = codec.serialized_equal(source, decoded, equal, mismatch);
    expect_ok({label, "_EQUAL_STATUS"}, status);
    if (!equal)
      `uvm_error(label, {"serialized round-trip mismatch: ", mismatch})
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_golden_roundtrip）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_golden_roundtrip(
    string label,
    rdma_codec_base codec,
    rdma_hw_model source,
    rdma_xtr_v1_golden_case golden,
    rdma_image_kind_e image_kind,
    int unsigned owner_generation,
    output rdma_hw_image image
  );
    image = null;
    if (golden == null) begin
      `uvm_error(label, "required golden body is null")
      return;
    end
    if (golden.payload.size() != 64) begin
      `uvm_error(label, "required golden body is not 64 bytes")
      return;
    end
    check_roundtrip_core(label, codec, source, image_kind, owner_generation,
                         image);
    if (image == null || image.bytes.size() != 64) return;
    foreach (golden.payload[i])
      if (image.bytes[i] != golden.payload[i])
        `uvm_error(label,
                   $sformatf("golden byte %0d got %02x expected %02x", i,
                             image.bytes[i], golden.payload[i]))
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_non_golden_roundtrip）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_non_golden_roundtrip(
    string label,
    rdma_codec_base codec,
    rdma_hw_model source,
    rdma_image_kind_e image_kind,
    int unsigned owner_generation,
    output rdma_hw_image image
  );
    check_roundtrip_core(label, codec, source, image_kind, owner_generation,
                         image);
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_decoded_equal）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_decoded_equal(
    string label,
    rdma_codec_base codec,
    rdma_hw_image image,
    rdma_mrt_model source
  );
    rdma_hw_model decoded;
    rdma_status status;
    bit equal;
    string mismatch;

    decoded = null;
    status = codec.decode(image, decoded);
    expect_ok({label, "_DECODE"}, status);
    if (decoded == null) begin
      `uvm_error(label, "successful decode published null")
      return;
    end
    status = decoded.validate();
    expect_ok({label, "_VALID"}, status);
    status = codec.serialized_equal(source, decoded, equal, mismatch);
    expect_ok({label, "_EQUAL_STATUS"}, status);
    if (!equal)
      `uvm_error(label, {"serialized decode mismatch: ", mismatch})
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_zero_stag_ambiguity）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_zero_stag_ambiguity(
    rdma_codec_base key_codec,
    rdma_codec_base register_codec
  );
    rdma_mrt_model key_model;
    rdma_mrt_model register_model;
    rdma_hw_model cloned;
    rdma_hw_image key_image;
    rdma_hw_image register_image;
    rdma_status status;

    key_model = make_mrt("mrt_key_stag0", RDMA_MR_PBL0);
    key_model.mr_h.object_id = 0;
    key_model.lkey = 32'h0000_00a5;
    key_model.rkey = key_model.lkey;
    cloned = clone_model(key_model, "MRT_REGISTER_STAG0_CLONE");
    if (!$cast(register_model, cloned)) begin
      `uvm_error("MRT_REGISTER_STAG0_CLONE", "model cast failed")
      return;
    end
    expect_ok("MRT_KEY_STAG0_MODEL_VALID", key_model.validate());
    expect_ok("MRT_REGISTER_STAG0_MODEL_VALID", register_model.validate());

    status = key_codec.encode(key_model, key_image);
    expect_ok("MRT_KEY_STAG0_ENCODE", status);
    status = register_codec.encode(register_model, register_image);
    expect_ok("MRT_REGISTER_STAG0_ENCODE", status);
    if (key_image == null || register_image == null) begin
      `uvm_error("MRT_STAG0_IMAGES", "successful encode published null")
      return;
    end
    if (key_image.bytes.size() != 64 || register_image.bytes.size() != 64)
      `uvm_error("MRT_STAG0_IMAGES", "encoded body is not 64 bytes")
    else foreach (key_image.bytes[i])
      if (key_image.bytes[i] != register_image.bytes[i])
        `uvm_error("MRT_STAG0_IDENTICAL",
                   $sformatf("payload byte %0d differs: %02x != %02x", i,
                             key_image.bytes[i], register_image.bytes[i]))
    expect_image_field("MRT_KEY_STAG0_PARENT", key_image,
                       XTR_V1_MRT_BODY_PARENT_STAG_IDX_WORD_BYTE_OFFSET,
                       XTR_V1_MRT_BODY_PARENT_STAG_IDX_LSB,
                       XTR_V1_MRT_BODY_PARENT_STAG_IDX_WIDTH, 0);
    expect_image_field("MRT_REGISTER_STAG0_PARENT", register_image,
                       XTR_V1_MRT_BODY_PARENT_STAG_IDX_WORD_BYTE_OFFSET,
                       XTR_V1_MRT_BODY_PARENT_STAG_IDX_LSB,
                       XTR_V1_MRT_BODY_PARENT_STAG_IDX_WIDTH, 0);

    // Isolated STAG0 bodies are intentionally ambiguous. Full requests rely
    // on exact opcode/registry identity to select the authenticated codec.
    check_decoded_equal("MRT_KEY_STAG0_AS_KEY", key_codec, key_image,
                        key_model);
    check_decoded_equal("MRT_KEY_STAG0_AS_REGISTER", register_codec,
                        key_image, key_model);
    check_decoded_equal("MRT_REGISTER_STAG0_AS_KEY", key_codec,
                        register_image, register_model);
    check_decoded_equal("MRT_REGISTER_STAG0_AS_REGISTER", register_codec,
                        register_image, register_model);
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_cqc_coordinates）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_cqc_coordinates(rdma_codec_base codec);
    rdma_cqc_model cqc;
    rdma_hw_image image;
    rdma_hw_image roundtrip_image;
    rdma_status status;
    bit [51:0] sd_page;
    bit [51:0] current_page;
    bit [51:0] next_page;

    cqc = make_cqc("cqc_coordinates");
    cqc.cq_h.object_id = 21'h12_345;
    cqc.ceq_h.object_id = 12'h5a5;
    cqc.state = RDMA_CONTEXT_VALID;
    cqc.depth = 1024;
    cqc.cqe_size_bytes = 64;
    cqc.threshold = 5;
    cqc.page_layout.mode = RDMA_OBJECT_HUGE_2M;
    cqc.page_layout.sd_base.value = 64'h1b23_4567_89ab_c000;
    cqc.page_layout.current_base.value = 64'h3c34_5678_9abc_d000;
    cqc.page_layout.current_valid = 1'b1;
    cqc.page_layout.next_base.value = 64'h5a12_3456_789a_b000;
    cqc.page_layout.next_valid = 1'b1;
    cqc.producer.index = 23'h155;
    cqc.producer.wrap = 1'b0;
    cqc.consumer.index = 23'h2aa;
    cqc.consumer.wrap = 1'b1;
    cqc.urc_enable = 1'b0;
    cqc.load_ci_done = 1'b0;
    cqc.last_arm_sequence = 2'd1;
    cqc.arm_sequence = 2'd2;
    cqc.arm_state = 2'd1;
    cqc.shadow_backing.value = 64'h4d45_6789_abcd_efc0;
    sd_page = cqc.page_layout.sd_base.value >> 12;
    current_page = cqc.page_layout.current_base.value >> 12;
    next_page = cqc.page_layout.next_base.value >> 12;

    status = codec.encode(cqc, image);
    expect_ok("CQC_COORDINATES_ENCODE", status);
    if (image == null) begin
      `uvm_error("CQC_COORDINATES_ENCODE",
                 "successful encode published null")
      return;
    end
`define CQC_EXPECT(STEM, EXPECTED) \
    expect_image_field({"CQC_COORDINATES_", `"STEM`"}, image, \
                       STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                       STEM``_WIDTH, EXPECTED);
    `CQC_EXPECT(XTR_V1_CQC_BODY_CQN, cqc.cq_h.object_id)
    `CQC_EXPECT(XTR_V1_CQC_BODY_CQ_SD_PBA, sd_page)
    `CQC_EXPECT(XTR_V1_CQC_BODY_CQ_SIZE, 10)
    `CQC_EXPECT(XTR_V1_CQC_BODY_URC_FLAG, cqc.urc_enable)
    `CQC_EXPECT(XTR_V1_CQC_BODY_CQ_ST, RDMA_CONTEXT_VALID)
    `CQC_EXPECT(XTR_V1_CQC_BODY_NXT_CQ_PD_PBA_H, next_page[51:44])
    `CQC_EXPECT(XTR_V1_CQC_BODY_CUR_PBA_VLD, cqc.page_layout.current_valid)
    `CQC_EXPECT(XTR_V1_CQC_BODY_CUR_CQ_PD_PBA, current_page)
    `CQC_EXPECT(XTR_V1_CQC_BODY_LOAD_CQ_CI_DONE, cqc.load_ci_done)
    `CQC_EXPECT(XTR_V1_CQC_BODY_LOAD_CQ_CI_TH, cqc.threshold)
    `CQC_EXPECT(XTR_V1_CQC_BODY_CQ_OM, RDMA_OBJECT_HUGE_2M)
    `CQC_EXPECT(XTR_V1_CQC_BODY_NXT_PBA_VLD, cqc.page_layout.next_valid)
    `CQC_EXPECT(XTR_V1_CQC_BODY_NXT_CQ_PD_PBA_L, next_page[43:0])
    `CQC_EXPECT(XTR_V1_CQC_BODY_CQ_PI, cqc.producer.index)
    `CQC_EXPECT(XTR_V1_CQC_BODY_CQ_PI_WRAP, cqc.producer.wrap)
    `CQC_EXPECT(XTR_V1_CQC_BODY_LAST_ARM_SN, cqc.last_arm_sequence)
    `CQC_EXPECT(XTR_V1_CQC_BODY_CQE_SIZE, 1)
    `CQC_EXPECT(XTR_V1_CQC_BODY_CEQN, cqc.ceq_h.object_id)
    `CQC_EXPECT(XTR_V1_CQC_BODY_SHADOW_PA, cqc.shadow_backing.value >> 6)
    `CQC_EXPECT(XTR_V1_CQC_BODY_CQ_CI, cqc.consumer.index)
    `CQC_EXPECT(XTR_V1_CQC_BODY_CQ_CI_WRAP, cqc.consumer.wrap)
    `CQC_EXPECT(XTR_V1_CQC_BODY_ARM_SN, cqc.arm_sequence)
    `CQC_EXPECT(XTR_V1_CQC_BODY_ARM_ST, cqc.arm_state)
`undef CQC_EXPECT
    check_non_golden_roundtrip("CQC_COORDINATES", codec, cqc,
                               RDMA_IMAGE_CQC, cqc.cq_h.generation,
                               roundtrip_image);
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_mrt_pbl1_coordinates）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_mrt_pbl1_coordinates(rdma_codec_base codec);
    rdma_mrt_model mrt;
    rdma_hw_image image;
    rdma_hw_image roundtrip_image;
    rdma_status status;
    bit [4:0] rights;

    mrt = make_mrt("mrt_pbl1_coordinates", RDMA_MR_PBL1);
    mrt.mr_h.object_id = 24'h12_3456;
    mrt.pd_h.object_id = 16'h3456;
    mrt.state = RDMA_CONTEXT_INVALID;
    mrt.iova.value = 64'h0123_4567_89ab_cdef;
    mrt.length = 64'h0000_1234_5678_9abc;
    mrt.lkey = {24'h12_3456, 8'ha5};
    mrt.rkey = mrt.lkey;
    mrt.access = '{local_write:1'b0, remote_read:1'b1,
                   remote_write:1'b0, memory_window_bind:1'b1,
                   remote_atomic:1'b0};
    mrt.object_type = XTR_V1_MEM_TYPE_MW_TYPE1;
    mrt.page_layout.host_page_size = RDMA_MR_PAGE_2M;
    mrt.page_layout.address_mode = RDMA_MR_ADDRESS_VA_BASED;
    mrt.page_layout.odp = 1'b0;
    mrt.page_layout.invalidate_enable = 1'b0;
    mrt.page_layout.payload_vf_enable = 1'b0;
    mrt.page_layout.payload_vf_id = 8'h5a;
    mrt.page_layout.mr_serial = 12'h5a5;
    mrt.page_layout.pba0.value = 64'h1234_5678_9abc_d000;
    mrt.page_layout.pba1.value = 64'h5678_9abc_def0_1000;
    rights = XTR_V1_RIGHT_REMOTE_READ | XTR_V1_RIGHT_BIND_WINDOW;

    status = codec.encode(mrt, image);
    expect_ok("MRT_PBL1_COORDINATES_ENCODE", status);
    if (image == null) begin
      `uvm_error("MRT_PBL1_COORDINATES_ENCODE",
                 "successful encode published null")
      return;
    end
`define MRT_EXPECT(STEM, EXPECTED) \
    expect_image_field({"MRT_PBL1_COORDINATES_", `"STEM`"}, image, \
                       STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                       STEM``_WIDTH, EXPECTED);
    `MRT_EXPECT(XTR_V1_MRT_BODY_STAG_IDX, mrt.mr_h.object_id)
    `MRT_EXPECT(XTR_V1_MRT_BODY_NXT_ST, XTR_V1_MR_ST_INVALID)
    `MRT_EXPECT(XTR_V1_MRT_BODY_STAG_KEY, mrt.lkey[7:0])
    `MRT_EXPECT(XTR_V1_MRT_BODY_PARENT_STAG_IDX, 0)
    `MRT_EXPECT(XTR_V1_MRT_BODY_PD_IDX, mrt.pd_h.object_id)
    `MRT_EXPECT(XTR_V1_MRT_BODY_PLD_VF_ID, mrt.page_layout.payload_vf_id)
    `MRT_EXPECT(XTR_V1_MRT_BODY_PLD_VF_EN,
                mrt.page_layout.payload_vf_enable)
    `MRT_EXPECT(XTR_V1_MRT_BODY_RIGHT, rights)
    `MRT_EXPECT(XTR_V1_MRT_BODY_TYPE, XTR_V1_MEM_TYPE_MW_TYPE1)
    `MRT_EXPECT(XTR_V1_MRT_BODY_HOST_PG_SIZE, XTR_V1_HOST_PAGE_2M)
    `MRT_EXPECT(XTR_V1_MRT_BODY_PBL_MODE, RDMA_MR_PBL1)
    `MRT_EXPECT(XTR_V1_MRT_BODY_ADDR_MODE, XTR_V1_ADDR_TYPE_VA_BASED)
    `MRT_EXPECT(XTR_V1_MRT_BODY_INVALIDATE_EN,
                mrt.page_layout.invalidate_enable)
    `MRT_EXPECT(XTR_V1_MRT_BODY_ST, XTR_V1_MR_ST_INVALID)
    `MRT_EXPECT(XTR_V1_MRT_BODY_LEN, mrt.length)
    `MRT_EXPECT(XTR_V1_MRT_BODY_ODP, mrt.page_layout.odp)
    `MRT_EXPECT(XTR_V1_MRT_BODY_INFO_STAG_KEY, mrt.lkey[7:0])
    `MRT_EXPECT(XTR_V1_MRT_BODY_START_VA, mrt.iova.value)
    `MRT_EXPECT(XTR_V1_MRT_BODY_PAYLOAD_PBA0,
                mrt.page_layout.pba0.value >> 12)
    `MRT_EXPECT(XTR_V1_MRT_BODY_MR_SN, mrt.page_layout.mr_serial)
    `MRT_EXPECT(XTR_V1_MRT_BODY_PAYLOAD_PBA1,
                mrt.page_layout.pba1.value >> 12)
`undef MRT_EXPECT
    check_non_golden_roundtrip("MRT_PBL1_COORDINATES", codec, mrt,
                               RDMA_IMAGE_MRT, mrt.mr_h.generation,
                               roundtrip_image);
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_srqc_coordinates）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_srqc_coordinates(rdma_codec_base codec);
    rdma_srqc_model srqc;
    rdma_hw_image image;
    rdma_hw_image roundtrip_image;
    rdma_status status;

    srqc = make_srqc("srqc_coordinates");
    srqc.srq_h.object_id = 16'h2468;
    srqc.pd_h.object_id = 16'h1357;
    srqc.state = RDMA_CONTEXT_VALID;
    srqc.depth = 1024;
    srqc.load_pi_threshold = 8'h5a;
    srqc.limit_threshold = 14'h1234;
    srqc.object_mode = RDMA_OBJECT_INDIRECT_4K;
    srqc.srfq_backing.value = 64'h4567_89ab_cdef_0000;
    srqc.shadow_backing.value = 64'h1234_5678_9abc_d000;
    srqc.producer.index = 15'h155;
    srqc.producer.wrap = 1'b0;
    srqc.arm_sequence = 2'd1;

    status = codec.encode(srqc, image);
    expect_ok("SRQC_COORDINATES_ENCODE", status);
    if (image == null) begin
      `uvm_error("SRQC_COORDINATES_ENCODE",
                 "successful encode published null")
      return;
    end
`define SRQC_EXPECT(STEM, EXPECTED) \
    expect_image_field({"SRQC_COORDINATES_", `"STEM`"}, image, \
                       STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                       STEM``_WIDTH, EXPECTED);
    `SRQC_EXPECT(XTR_V1_SRQC_BODY_SRFQN, srqc.srq_h.object_id)
    `SRQC_EXPECT(XTR_V1_SRQC_BODY_SRFQ_ST, RDMA_CONTEXT_VALID)
    `SRQC_EXPECT(XTR_V1_SRQC_BODY_LOAD_SRFQ_PI_TH,
                 srqc.load_pi_threshold)
    `SRQC_EXPECT(XTR_V1_SRQC_BODY_SHADOW_PA,
                 srqc.shadow_backing.value >> 12)
    `SRQC_EXPECT(XTR_V1_SRQC_BODY_PD_IDX, srqc.pd_h.object_id)
    `SRQC_EXPECT(XTR_V1_SRQC_BODY_SRFQ_PBA,
                 srqc.srfq_backing.value >> 12)
    `SRQC_EXPECT(XTR_V1_SRQC_BODY_SRFQ_SIZE, 10)
    `SRQC_EXPECT(XTR_V1_SRQC_BODY_SRFQ_OM, RDMA_OBJECT_INDIRECT_4K)
    `SRQC_EXPECT(XTR_V1_SRQC_BODY_SRFQ_PI_WRAP, srqc.producer.wrap)
    `SRQC_EXPECT(XTR_V1_SRQC_BODY_SRFQ_PI, srqc.producer.index)
    `SRQC_EXPECT(XTR_V1_SRQC_BODY_LIMIT_TH, srqc.limit_threshold)
    `SRQC_EXPECT(XTR_V1_SRQC_BODY_ARM_SN, srqc.arm_sequence)
`undef SRQC_EXPECT
    check_non_golden_roundtrip("SRQC_COORDINATES", codec, srqc,
                               RDMA_IMAGE_SRQC, srqc.srq_h.generation,
                               roundtrip_image);
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_eq_image_fields）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_eq_image_fields(
    string label,
    rdma_hw_image image,
    int unsigned eqn,
    rdma_context_state_e state,
    int unsigned depth_code,
    bit [51:0] next_page,
    bit [51:0] current_page,
    bit current_valid,
    rdma_ring_position producer,
    rdma_object_mode_e mode,
    int unsigned vector_id,
    rdma_ring_position consumer
  );
`define EQC_EXPECT(STEM, EXPECTED) \
    expect_image_field({label, "_", `"STEM`"}, image, \
                       STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                       STEM``_WIDTH, EXPECTED);
    `EQC_EXPECT(XTR_V1_EQC_BODY_EQN, eqn)
    `EQC_EXPECT(XTR_V1_EQC_BODY_EQ_ST, state)
    `EQC_EXPECT(XTR_V1_EQC_BODY_EQ_SIZE, depth_code)
    `EQC_EXPECT(XTR_V1_EQC_BODY_NXT_EQ_PBA, next_page)
    `EQC_EXPECT(XTR_V1_EQC_BODY_CUR_EQ_PBA, current_page)
    `EQC_EXPECT(XTR_V1_EQC_BODY_CUR_PBA_VLD, current_valid)
    `EQC_EXPECT(XTR_V1_EQC_BODY_EQ_PI_WRAP, producer.wrap)
    `EQC_EXPECT(XTR_V1_EQC_BODY_EQ_PI, producer.index)
    `EQC_EXPECT(XTR_V1_EQC_BODY_EQ_OM, mode)
    `EQC_EXPECT(XTR_V1_EQC_BODY_MSI_X_IDX, vector_id)
    `EQC_EXPECT(XTR_V1_EQC_BODY_EQ_CI_WRAP, consumer.wrap)
    `EQC_EXPECT(XTR_V1_EQC_BODY_EQ_CI, consumer.index)
`undef EQC_EXPECT
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_eq_coordinates）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_eq_coordinates(
    rdma_codec_base ceq_codec,
    rdma_codec_base aeq_codec
  );
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;
    rdma_hw_image ceq_image;
    rdma_hw_image aeq_image;
    rdma_hw_image roundtrip_image;
    rdma_status status;

    ceqc = make_ceqc("ceqc_coordinates");
    ceqc.ceq_h.object_id = 12'h321;
    ceqc.state = RDMA_CONTEXT_VALID;
    ceqc.depth = 2048;
    ceqc.vector_id = 16'h4567;
    ceqc.page_layout.mode = RDMA_OBJECT_INDIRECT_4K;
    ceqc.page_layout.current_base.value = 64'h2345_6789_abcd_e000;
    ceqc.page_layout.current_valid = 1'b1;
    ceqc.page_layout.next_base.value = 64'h3456_789a_bcde_f000;
    ceqc.page_layout.next_valid = 1'b1;
    ceqc.producer.index = 18'h234;
    ceqc.producer.wrap = 1'b0;
    ceqc.consumer.index = 18'h567;
    ceqc.consumer.wrap = 1'b1;
    status = ceq_codec.encode(ceqc, ceq_image);
    expect_ok("CEQC_COORDINATES_ENCODE", status);
    if (ceq_image == null)
      `uvm_error("CEQC_COORDINATES_ENCODE",
                 "successful encode published null")
    else begin
      if (ceq_image.image_kind != RDMA_IMAGE_CEQC)
        `uvm_error("CEQC_COORDINATES_KIND", "CEQC identity was not preserved")
      check_eq_image_fields("CEQC_COORDINATES", ceq_image,
                            ceqc.ceq_h.object_id, ceqc.state, 11,
                            ceqc.page_layout.next_base.value >> 12,
                            ceqc.page_layout.current_base.value >> 12,
                            ceqc.page_layout.current_valid, ceqc.producer,
                            ceqc.page_layout.mode, ceqc.vector_id,
                            ceqc.consumer);
      check_non_golden_roundtrip("CEQC_COORDINATES", ceq_codec, ceqc,
                                 RDMA_IMAGE_CEQC, ceqc.ceq_h.generation,
                                 roundtrip_image);
    end

    aeqc = make_aeqc("aeqc_coordinates");
    aeqc.aeq_h.object_id = 12'h654;
    aeqc.state = RDMA_CONTEXT_INVALID;
    aeqc.depth = 4096;
    aeqc.vector_id = 16'h89ab;
    aeqc.page_layout.mode = RDMA_OBJECT_INDIRECT_4K;
    aeqc.page_layout.current_base.value = 64'h6789_abcd_ef01_2000;
    aeqc.page_layout.current_valid = 1'b1;
    aeqc.page_layout.next_base.value = 64'h789a_bcde_f012_3000;
    aeqc.page_layout.next_valid = 1'b1;
    aeqc.producer.index = 18'h345;
    aeqc.producer.wrap = 1'b1;
    aeqc.consumer.index = 18'h678;
    aeqc.consumer.wrap = 1'b0;
    status = aeq_codec.encode(aeqc, aeq_image);
    expect_ok("AEQC_COORDINATES_ENCODE", status);
    if (aeq_image == null)
      `uvm_error("AEQC_COORDINATES_ENCODE",
                 "successful encode published null")
    else begin
      if (aeq_image.image_kind != RDMA_IMAGE_AEQC)
        `uvm_error("AEQC_COORDINATES_KIND", "AEQC identity was not preserved")
      check_eq_image_fields("AEQC_COORDINATES", aeq_image,
                            aeqc.aeq_h.object_id, aeqc.state, 12,
                            aeqc.page_layout.next_base.value >> 12,
                            aeqc.page_layout.current_base.value >> 12,
                            aeqc.page_layout.current_valid, aeqc.producer,
                            aeqc.page_layout.mode, aeqc.vector_id,
                            aeqc.consumer);
      check_non_golden_roundtrip("AEQC_COORDINATES", aeq_codec, aeqc,
                                 RDMA_IMAGE_AEQC, aeqc.aeq_h.generation,
                                 roundtrip_image);
    end
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_reserved_qwords）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_reserved_qwords(
    string label,
    rdma_codec_base codec,
    rdma_hw_image valid,
    rdma_image_kind_e image_kind,
    bit [7:0] opcode,
    rdma_mr_pbl_mode_e pbl_mode
  );
    bit [63:0] mask;
    bit [63:0] reserved;
    bit [63:0] corrupt_word;
    rdma_hw_image corrupt;
    for (int unsigned q = 0; q < 8; q++) begin
      mask = '0;
      if (!body_mask(image_kind, opcode, pbl_mode, q, mask)) begin
        `uvm_error(label, $sformatf("mask lookup failed at qword %0d", q))
        continue;
      end
      reserved = ~mask;
      if (reserved == 0)
        continue;
      corrupt = clone_image(valid, {label, "_reserved"});
      corrupt_word = image_word(corrupt, q);
      for (int unsigned bit_index = 0; bit_index < 64; bit_index++) begin
        if (reserved[bit_index]) begin
          corrupt_word[bit_index] = 1'b1;
          break;
        end
      end
      for (int unsigned i = 0; i < 8; i++)
        corrupt.bytes[(q * 8) + i] = corrupt_word[63 - (i * 8) -: 8];
      expect_decode_failure($sformatf("%s_RESERVED_Q%0d", label, q),
                            codec, corrupt);
    end
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_metadata_failures）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_metadata_failures(
    rdma_codec_base codec,
    rdma_hw_image valid
  );
    rdma_hw_image corrupt;
    corrupt = clone_image(valid, "BODY_META_LENGTH");
    corrupt.length = 63;
    expect_decode_failure("BODY_META_LENGTH", codec, corrupt);
    corrupt = clone_image(valid, "BODY_META_BYTES");
    void'(corrupt.bytes.pop_back());
    corrupt.length = 63;
    expect_decode_failure("BODY_META_BYTES", codec, corrupt);
    corrupt = clone_image(valid, "BODY_META_ALIGNMENT");
    corrupt.alignment = 8;
    expect_decode_failure("BODY_META_ALIGNMENT", codec, corrupt);
    corrupt = clone_image(valid, "BODY_META_ENDIAN");
    corrupt.endian = RDMA_ENDIAN_LITTLE;
    expect_decode_failure("BODY_META_ENDIAN", codec, corrupt);
    corrupt = clone_image(valid, "BODY_META_KIND");
    corrupt.image_kind = RDMA_IMAGE_AEQC;
    expect_decode_failure("BODY_META_KIND", codec, corrupt);
    corrupt = clone_image(valid, "BODY_META_VERSION");
    corrupt.hardware_version++;
    expect_decode_failure("BODY_META_VERSION", codec, corrupt);
    corrupt = clone_image(valid, "BODY_META_TARGET_KIND");
    corrupt.write_target_kind = RDMA_HW_TARGET_BACKING;
    expect_decode_failure("BODY_META_TARGET_KIND", codec, corrupt);
    corrupt = clone_image(valid, "BODY_META_BACKING_TARGET");
    corrupt.backing_target.value = 64'h1000;
    expect_decode_failure("BODY_META_BACKING_TARGET", codec, corrupt);
    corrupt = clone_image(valid, "BODY_META_HMC_TARGET");
    corrupt.hmc_target.value = 64'h1000;
    expect_decode_failure("BODY_META_HMC_TARGET", codec, corrupt);
    corrupt = clone_image(valid, "BODY_META_BAR_TARGET");
    corrupt.bar_target.value = 64'h1000;
    expect_decode_failure("BODY_META_BAR_TARGET", codec, corrupt);
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_registry_contract）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_registry_contract(
    rdma_codec_registry registry
  );
    rdma_codec_registry empty_registry;
    rdma_codec_key key;
    rdma_codec_base codec;
    rdma_status status;
    string keys[$];
    string expected[6] = '{
      "xtr_v1|2|cqc|create|0c",
      "xtr_v1|3|mrt|key_alloc|04",
      "xtr_v1|3|mrt|register|05",
      "xtr_v1|4|srqc|create|35",
      "xtr_v1|5|ceqc|create|10",
      "xtr_v1|6|aeqc|create|14"
    };

    registry.list_keys(keys);
    if (keys.size() != 6)
      `uvm_error("BODY_REGISTRY_COUNT",
                 $sformatf("expected six keys, got %0d", keys.size()))
    else foreach (expected[i])
      if (keys[i] != expected[i])
        `uvm_error("BODY_REGISTRY_KEYS",
                   $sformatf("key %0d got %s expected %s", i, keys[i],
                             expected[i]))

    empty_registry = rdma_codec_registry::type_id::create("empty_registry");
    empty_registry.clear();
    key = body_key(RDMA_IMAGE_CQC, "cqc", "create", XTR_V1_OP_CQC_CREATE);
    codec = rdma_xtr_v1_cqc_create_body_codec::type_id::create("sentinel");
    status = empty_registry.lookup(key, codec);
    expect_status("BODY_REGISTRY_MISSING", status, RDMA_SC_UNSUPPORTED_OPCODE);
    if (codec != null)
      `uvm_error("BODY_REGISTRY_MISSING", "missing lookup published a codec")

    key.opcode = XTR_V1_OP_CQC_MODIFY;
    status = registry.lookup(key, codec);
    expect_status("BODY_REGISTRY_WRONG_OPCODE", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);
    if (codec != null)
      `uvm_error("BODY_REGISTRY_WRONG_OPCODE", "wrong opcode published a codec")
    key = body_key(RDMA_IMAGE_CQC, "cqc", "register", XTR_V1_OP_CQC_CREATE);
    status = registry.lookup(key, codec);
    expect_status("BODY_REGISTRY_WRONG_VARIANT", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);
    if (codec != null)
      `uvm_error("BODY_REGISTRY_WRONG_VARIANT", "wrong variant published a codec")
    key = body_key(RDMA_IMAGE_CQC, "srqc", "create", XTR_V1_OP_CQC_CREATE);
    status = registry.lookup(key, codec);
    expect_status("BODY_REGISTRY_WRONG_OBJECT", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);
    if (codec != null)
      `uvm_error("BODY_REGISTRY_WRONG_OBJECT", "wrong object published a codec")
    key = body_key(RDMA_IMAGE_SRQC, "cqc", "create", XTR_V1_OP_CQC_CREATE);
    status = registry.lookup(key, codec);
    expect_status("BODY_REGISTRY_WRONG_KIND", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);
    if (codec != null)
      `uvm_error("BODY_REGISTRY_WRONG_KIND", "wrong kind published a codec")
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_cqc_negatives）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_cqc_negatives(
    rdma_codec_base codec,
    rdma_cqc_model source,
    rdma_hw_image valid
  );
    rdma_cqc_model changed;
    rdma_hw_image corrupt;

    if (!$cast(changed, clone_model(source, "CQC_WIDTH_CQ"))) return;
    changed.cq_h.object_id = 21'h1f_ffff + 1;
    expect_encode_failure("CQC_CQ_ID_WIDTH", codec, changed);
    if (!$cast(changed, clone_model(source, "CQC_WIDTH_CEQ"))) return;
    changed.ceq_h.object_id = 12'hfff + 1;
    expect_encode_failure("CQC_CEQ_ID_WIDTH", codec, changed);

    if (!$cast(changed, clone_model(source, "CQC_SD_ALIGNMENT"))) return;
    changed.page_layout.sd_base.value++;
    expect_encode_failure("CQC_SD_ALIGNMENT", codec, changed);
    if (!$cast(changed, clone_model(source, "CQC_CURRENT_ALIGNMENT"))) return;
    changed.page_layout.current_base.value++;
    expect_encode_failure("CQC_CURRENT_ALIGNMENT", codec, changed);
    if (!$cast(changed, clone_model(source, "CQC_NEXT_ALIGNMENT"))) return;
    changed.page_layout.next_base.value++;
    expect_encode_failure("CQC_NEXT_ALIGNMENT", codec, changed);
    if (!$cast(changed, clone_model(source, "CQC_SHADOW_ALIGNMENT"))) return;
    changed.shadow_backing.value++;
    expect_encode_failure("CQC_SHADOW_ALIGNMENT", codec, changed);
    if (!$cast(changed, clone_model(source, "CQC_DIRECT_MODE"))) return;
    changed.page_layout.mode = RDMA_OBJECT_DIRECT_4K;
    expect_encode_failure("CQC_DIRECT_MODE", codec, changed);
    if (!$cast(changed, clone_model(source, "CQC_CQE_SIZE"))) return;
    changed.cqe_size_bytes = 256;
    expect_encode_failure("CQC_CQE_SIZE", codec, changed);

    corrupt = clone_image(valid, "CQC_STATE_CORRUPT");
    set_image_field(corrupt, XTR_V1_CQC_BODY_CQ_ST_WORD_BYTE_OFFSET,
                    XTR_V1_CQC_BODY_CQ_ST_LSB,
                    XTR_V1_CQC_BODY_CQ_ST_WIDTH, 3);
    expect_decode_failure("CQC_STATE_CORRUPT", codec, corrupt);
    corrupt = clone_image(valid, "CQC_CQE_CODE_CORRUPT");
    set_image_field(corrupt, XTR_V1_CQC_BODY_CQE_SIZE_WORD_BYTE_OFFSET,
                    XTR_V1_CQC_BODY_CQE_SIZE_LSB,
                    XTR_V1_CQC_BODY_CQE_SIZE_WIDTH, 3);
    expect_decode_failure("CQC_CQE_CODE_CORRUPT", codec, corrupt);
    corrupt = clone_image(valid, "CQC_ARM_STATE_CORRUPT");
    set_image_field(corrupt, XTR_V1_CQC_BODY_ARM_ST_WORD_BYTE_OFFSET,
                    XTR_V1_CQC_BODY_ARM_ST_LSB,
                    XTR_V1_CQC_BODY_ARM_ST_WIDTH, 3);
    expect_decode_failure("CQC_ARM_STATE_CORRUPT", codec, corrupt);
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_mrt_negatives）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_mrt_negatives(
    rdma_codec_base key_codec,
    rdma_codec_base register_codec,
    rdma_mrt_model pbl0,
    rdma_mrt_model pbl1,
    rdma_mrt_model pbl2,
    rdma_hw_image key_image,
    rdma_hw_image pbl0_image,
    rdma_hw_image pbl1_image,
    rdma_hw_image pbl2_image
  );
    rdma_mrt_model changed;
    rdma_hw_image corrupt;
    rdma_hw_model decoded;
    rdma_status status;
    bit equal;
    string mismatch;

    if (!$cast(changed, clone_model(pbl0, "MRT_WIDTH_MR"))) return;
    changed.mr_h.object_id = 24'hff_ffff + 1;
    expect_encode_failure("MRT_MR_ID_WIDTH", register_codec, changed);
    if (!$cast(changed, clone_model(pbl0, "MRT_WIDTH_PD"))) return;
    changed.pd_h.object_id = 16'hffff + 1;
    expect_encode_failure("MRT_PD_ID_WIDTH", register_codec, changed);
    if (!$cast(changed, clone_model(pbl0, "MRT_PBA0_ALIGNMENT"))) return;
    changed.page_layout.pba0.value++;
    expect_encode_failure("MRT_PBA0_ALIGNMENT", register_codec, changed);
    if (!$cast(changed, clone_model(pbl1, "MRT_PBA1_ALIGNMENT"))) return;
    changed.page_layout.pba1.value++;
    expect_encode_failure("MRT_PBA1_ALIGNMENT", register_codec, changed);
    if (!$cast(changed, clone_model(pbl0, "MRT_PAGE_64K"))) return;
    changed.page_layout.host_page_size = RDMA_MR_PAGE_64K;
    expect_encode_failure("MRT_PAGE_64K", register_codec, changed);
    if (!$cast(changed, clone_model(pbl0, "MRT_ERROR_STATE"))) return;
    changed.state = RDMA_CONTEXT_ERROR;
    expect_encode_failure("MRT_ERROR_STATE", register_codec, changed);

    corrupt = clone_image(pbl0_image, "MRT_STATE_MIRROR");
    set_image_field(corrupt, XTR_V1_MRT_BODY_NXT_ST_WORD_BYTE_OFFSET,
                    XTR_V1_MRT_BODY_NXT_ST_LSB,
                    XTR_V1_MRT_BODY_NXT_ST_WIDTH, XTR_V1_MR_ST_INVALID);
    expect_decode_failure("MRT_STATE_MIRROR", register_codec, corrupt);
    corrupt = clone_image(pbl0_image, "MRT_KEY_MIRROR");
    set_image_field(corrupt, XTR_V1_MRT_BODY_INFO_STAG_KEY_WORD_BYTE_OFFSET,
                    XTR_V1_MRT_BODY_INFO_STAG_KEY_LSB,
                    XTR_V1_MRT_BODY_INFO_STAG_KEY_WIDTH, 8'hfe);
    expect_decode_failure("MRT_KEY_MIRROR", register_codec, corrupt);
    corrupt = clone_image(pbl0_image, "MRT_PBL0_EXTRA_PBA1");
    set_image_field(corrupt, XTR_V1_MRT_BODY_PAYLOAD_PBA1_WORD_BYTE_OFFSET,
                    XTR_V1_MRT_BODY_PAYLOAD_PBA1_LSB,
                    XTR_V1_MRT_BODY_PAYLOAD_PBA1_WIDTH, 1);
    expect_decode_failure("MRT_PBL0_EXTRA_PBA1", register_codec, corrupt);
    corrupt = clone_image(pbl2_image, "MRT_PBL2_EXTRA_PBA0");
    set_image_field(corrupt, XTR_V1_MRT_BODY_PAYLOAD_PBA0_WORD_BYTE_OFFSET,
                    XTR_V1_MRT_BODY_PAYLOAD_PBA0_LSB, 1, 1);
    expect_decode_failure("MRT_PBL2_EXTRA_PBA0", register_codec, corrupt);
    corrupt = clone_image(pbl0_image, "MRT_PBL_INVALID");
    set_image_field(corrupt, XTR_V1_MRT_BODY_PBL_MODE_WORD_BYTE_OFFSET,
                    XTR_V1_MRT_BODY_PBL_MODE_LSB,
                    XTR_V1_MRT_BODY_PBL_MODE_WIDTH, 3);
    expect_decode_failure("MRT_PBL_INVALID", register_codec, corrupt);

    decoded = rdma_mrt_model::type_id::create("mrt_cross_sentinel");
    status = key_codec.decode(pbl0_image, decoded);
    expect_status("MRT_REGISTER_AS_KEY_ALLOC", status, RDMA_SC_CODEC_ERROR);
    if (decoded != null)
      `uvm_error("MRT_REGISTER_AS_KEY_ALLOC", "cross decode published model")
    decoded = rdma_mrt_model::type_id::create("mrt_cross_sentinel_2");
    status = register_codec.decode(key_image, decoded);
    expect_status("MRT_KEY_ALLOC_AS_REGISTER", status, RDMA_SC_CODEC_ERROR);
    if (decoded != null)
      `uvm_error("MRT_KEY_ALLOC_AS_REGISTER", "cross decode published model")

    if (!$cast(changed, clone_model(pbl0, "MRT_NORMALIZED_RIGHTS"))) return;
    changed.access.local_write = 1'b0;
    status = register_codec.serialized_equal(pbl0, changed, equal, mismatch);
    expect_ok("MRT_NORMALIZED_RIGHTS", status);
    if (!equal)
      `uvm_error("MRT_NORMALIZED_RIGHTS", mismatch)
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_srqc_negatives）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_srqc_negatives(
    rdma_codec_base codec,
    rdma_srqc_model source,
    rdma_hw_image valid
  );
    rdma_srqc_model changed;
    rdma_hw_image corrupt;
    if (!$cast(changed, clone_model(source, "SRQC_WIDTH_SRQ"))) return;
    changed.srq_h.object_id = 16'hffff + 1;
    expect_encode_failure("SRQC_SRQ_ID_WIDTH", codec, changed);
    if (!$cast(changed, clone_model(source, "SRQC_WIDTH_PD"))) return;
    changed.pd_h.object_id = 16'hffff + 1;
    expect_encode_failure("SRQC_PD_ID_WIDTH", codec, changed);
    if (!$cast(changed, clone_model(source, "SRQC_PBA_ALIGNMENT"))) return;
    changed.srfq_backing.value++;
    expect_encode_failure("SRQC_PBA_ALIGNMENT", codec, changed);
    if (!$cast(changed, clone_model(source, "SRQC_SHADOW_ALIGNMENT"))) return;
    changed.shadow_backing.value++;
    expect_encode_failure("SRQC_SHADOW_ALIGNMENT", codec, changed);

    corrupt = clone_image(valid, "SRQC_RESERVED_GAP_Q3");
    set_image_field(corrupt, 24, 0, 1, 1);
    expect_decode_failure("SRQC_RESERVED_GAP_Q3", codec, corrupt);
    corrupt = clone_image(valid, "SRQC_RESERVED_GAP_Q4");
    set_image_field(corrupt, 32, 0, 1, 1);
    expect_decode_failure("SRQC_RESERVED_GAP_Q4", codec, corrupt);
    corrupt = clone_image(valid, "SRQC_STATE_CORRUPT");
    set_image_field(corrupt, XTR_V1_SRQC_BODY_SRFQ_ST_WORD_BYTE_OFFSET,
                    XTR_V1_SRQC_BODY_SRFQ_ST_LSB,
                    XTR_V1_SRQC_BODY_SRFQ_ST_WIDTH, 3);
    expect_decode_failure("SRQC_STATE_CORRUPT", codec, corrupt);
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_eq_negatives）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_eq_negatives(
    rdma_codec_base ceq_codec,
    rdma_codec_base aeq_codec,
    rdma_ceqc_model ceq,
    rdma_aeqc_model aeq,
    rdma_hw_image ceq_image,
    rdma_hw_image aeq_image
  );
    rdma_ceqc_model changed_ceq;
    rdma_aeqc_model changed_aeq;
    rdma_hw_image corrupt;
    rdma_hw_model decoded;
    rdma_status status;

    if (!$cast(changed_ceq, clone_model(ceq, "CEQC_WIDTH"))) return;
    changed_ceq.ceq_h.object_id = 12'hfff + 1;
    expect_encode_failure("CEQC_ID_WIDTH", ceq_codec, changed_ceq);
    if (!$cast(changed_aeq, clone_model(aeq, "AEQC_WIDTH"))) return;
    changed_aeq.aeq_h.object_id = 12'hfff + 1;
    expect_encode_failure("AEQC_ID_WIDTH", aeq_codec, changed_aeq);
    if (!$cast(changed_ceq, clone_model(ceq, "CEQC_CURRENT_ALIGNMENT"))) return;
    changed_ceq.page_layout.current_base.value++;
    expect_encode_failure("CEQC_CURRENT_ALIGNMENT", ceq_codec, changed_ceq);
    if (!$cast(changed_ceq, clone_model(ceq, "CEQC_NEXT_ALIGNMENT"))) return;
    changed_ceq.page_layout.next_base.value++;
    expect_encode_failure("CEQC_NEXT_ALIGNMENT", ceq_codec, changed_ceq);
    if (!$cast(changed_aeq, clone_model(aeq, "AEQC_CURRENT_ALIGNMENT"))) return;
    changed_aeq.page_layout.current_base.value++;
    expect_encode_failure("AEQC_CURRENT_ALIGNMENT", aeq_codec, changed_aeq);
    if (!$cast(changed_aeq, clone_model(aeq, "AEQC_NEXT_ALIGNMENT"))) return;
    changed_aeq.page_layout.next_base.value++;
    expect_encode_failure("AEQC_NEXT_ALIGNMENT", aeq_codec, changed_aeq);
    if (!$cast(changed_ceq, clone_model(ceq, "CEQC_DIRECT_MODE"))) return;
    changed_ceq.page_layout.mode = RDMA_OBJECT_DIRECT_4K;
    expect_encode_failure("CEQC_DIRECT_MODE", ceq_codec, changed_ceq);
    if (!$cast(changed_aeq, clone_model(aeq, "AEQC_HUGE_MODE"))) return;
    changed_aeq.page_layout.mode = RDMA_OBJECT_HUGE_2M;
    expect_encode_failure("AEQC_HUGE_MODE", aeq_codec, changed_aeq);

    corrupt = clone_image(ceq_image, "EQ_WRONG_KIND");
    corrupt.image_kind = RDMA_IMAGE_AEQC;
    expect_decode_failure("EQ_WRONG_KIND", ceq_codec, corrupt);
    corrupt = clone_image(ceq_image, "EQ_STATE_CORRUPT");
    set_image_field(corrupt, XTR_V1_EQC_BODY_EQ_ST_WORD_BYTE_OFFSET,
                    XTR_V1_EQC_BODY_EQ_ST_LSB,
                    XTR_V1_EQC_BODY_EQ_ST_WIDTH, 3);
    expect_decode_failure("EQ_STATE_CORRUPT", ceq_codec, corrupt);

    decoded = rdma_aeqc_model::type_id::create("ceq_as_aeq_sentinel");
    status = aeq_codec.decode(ceq_image, decoded);
    expect_status("CEQC_AS_AEQC", status, RDMA_SC_CODEC_ERROR);
    if (decoded != null)
      `uvm_error("CEQC_AS_AEQC", "cross decode published model")
    decoded = rdma_ceqc_model::type_id::create("aeq_as_ceq_sentinel");
    status = ceq_codec.decode(aeq_image, decoded);
    expect_status("AEQC_AS_CEQC", status, RDMA_SC_CODEC_ERROR);
    if (decoded != null)
      `uvm_error("AEQC_AS_CEQC", "cross decode published model")
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_ceqc_next_invalid）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_ceqc_next_invalid(
    rdma_codec_base codec
  );
    rdma_ceqc_model model;
    rdma_ceqc_model snapshot;
    rdma_hw_image image;
    rdma_status status;

    model = make_ceqc("ceqc_next_invalid");
    model.page_layout.next_valid = 1'b0;
    status = model.validate();
    expect_ok("CEQC_NEXT_INVALID_MODEL_VALID", status);
    if (!$cast(snapshot,
               clone_model(model, "CEQC_NEXT_INVALID_SNAPSHOT")))
      return;
    if (snapshot == model || snapshot.ceq_h == model.ceq_h ||
        snapshot.page_layout == model.page_layout ||
        snapshot.producer == model.producer ||
        snapshot.consumer == model.consumer) begin
      `uvm_error("CEQC_NEXT_INVALID_SNAPSHOT",
                 "model snapshot is not a deep copy")
      return;
    end

    image = rdma_hw_image::type_id::create("ceqc_next_invalid_stale");
    status = codec.encode(model, image);
    expect_status("CEQC_NEXT_INVALID", status, RDMA_SC_INVALID_ARGUMENT);
    if (image != null)
      `uvm_error("CEQC_NEXT_INVALID", "failed encode published an image")
    if (model.ceq_h == null || snapshot.ceq_h == null ||
        !model.ceq_h.same_instance(snapshot.ceq_h) ||
        model.state != snapshot.state || model.depth != snapshot.depth ||
        model.vector_id != snapshot.vector_id ||
        model.page_layout == null || snapshot.page_layout == null ||
        model.page_layout.mode != snapshot.page_layout.mode ||
        model.page_layout.sd_base.value !=
          snapshot.page_layout.sd_base.value ||
        model.page_layout.current_base.value !=
          snapshot.page_layout.current_base.value ||
        model.page_layout.current_valid !=
          snapshot.page_layout.current_valid ||
        model.page_layout.next_base.value !=
          snapshot.page_layout.next_base.value ||
        model.page_layout.next_valid != snapshot.page_layout.next_valid ||
        model.producer == null || snapshot.producer == null ||
        model.producer.index != snapshot.producer.index ||
        model.producer.wrap != snapshot.producer.wrap ||
        model.consumer == null || snapshot.consumer == null ||
        model.consumer.index != snapshot.consumer.index ||
        model.consumer.wrap != snapshot.consumer.wrap)
      `uvm_error("CEQC_NEXT_INVALID_IMMUTABLE",
                 "failed encode mutated the input model")
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_aeqc_next_invalid）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function automatic void check_aeqc_next_invalid(
    rdma_codec_base codec
  );
    rdma_aeqc_model model;
    rdma_aeqc_model snapshot;
    rdma_hw_image image;
    rdma_status status;

    model = make_aeqc("aeqc_next_invalid");
    model.page_layout.next_valid = 1'b0;
    status = model.validate();
    expect_ok("AEQC_NEXT_INVALID_MODEL_VALID", status);
    if (!$cast(snapshot,
               clone_model(model, "AEQC_NEXT_INVALID_SNAPSHOT")))
      return;
    if (snapshot == model || snapshot.aeq_h == model.aeq_h ||
        snapshot.page_layout == model.page_layout ||
        snapshot.producer == model.producer ||
        snapshot.consumer == model.consumer) begin
      `uvm_error("AEQC_NEXT_INVALID_SNAPSHOT",
                 "model snapshot is not a deep copy")
      return;
    end

    image = rdma_hw_image::type_id::create("aeqc_next_invalid_stale");
    status = codec.encode(model, image);
    expect_status("AEQC_NEXT_INVALID", status, RDMA_SC_INVALID_ARGUMENT);
    if (image != null)
      `uvm_error("AEQC_NEXT_INVALID", "failed encode published an image")
    if (model.aeq_h == null || snapshot.aeq_h == null ||
        !model.aeq_h.same_instance(snapshot.aeq_h) ||
        model.state != snapshot.state || model.depth != snapshot.depth ||
        model.vector_id != snapshot.vector_id ||
        model.page_layout == null || snapshot.page_layout == null ||
        model.page_layout.mode != snapshot.page_layout.mode ||
        model.page_layout.sd_base.value !=
          snapshot.page_layout.sd_base.value ||
        model.page_layout.current_base.value !=
          snapshot.page_layout.current_base.value ||
        model.page_layout.current_valid !=
          snapshot.page_layout.current_valid ||
        model.page_layout.next_base.value !=
          snapshot.page_layout.next_base.value ||
        model.page_layout.next_valid != snapshot.page_layout.next_valid ||
        model.producer == null || snapshot.producer == null ||
        model.producer.index != snapshot.producer.index ||
        model.producer.wrap != snapshot.producer.wrap ||
        model.consumer == null || snapshot.consumer == null ||
        model.consumer.index != snapshot.consumer.index ||
        model.consumer.wrap != snapshot.consumer.wrap)
      `uvm_error("AEQC_NEXT_INVALID_IMMUTABLE",
                 "failed encode mutated the input model")
  endfunction

  // 功能：执行 UVM 阶段任务，驱动测试场景并在结束时释放阶段 objection（接口 run_phase）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task run_phase(uvm_phase phase);
    rdma_codec_registry registry;
    rdma_codec_base cqc_codec;
    rdma_codec_base mrt_key_codec;
    rdma_codec_base mrt_register_codec;
    rdma_codec_base srqc_codec;
    rdma_codec_base ceqc_codec;
    rdma_codec_base aeqc_codec;
    rdma_status status;
    rdma_xtr_v1_golden_case cases[$];
    rdma_xtr_v1_golden_case cqc_golden;
    rdma_xtr_v1_golden_case mrt0_golden;
    rdma_xtr_v1_golden_case mrt1_golden;
    rdma_xtr_v1_golden_case mrt2_golden;
    rdma_xtr_v1_golden_case mrt_key0_golden;
    rdma_xtr_v1_golden_case mrt_key1_golden;
    rdma_xtr_v1_golden_case mrt_key2_golden;
    rdma_xtr_v1_golden_case srqc_golden;
    rdma_xtr_v1_golden_case ceqc_golden;
    rdma_xtr_v1_golden_case aeqc_golden;
    string error;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt0;
    rdma_mrt_model mrt1;
    rdma_mrt_model mrt2;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;
    rdma_hw_image cqc_image;
    rdma_hw_image mrt0_image;
    rdma_hw_image mrt1_image;
    rdma_hw_image mrt2_image;
    rdma_hw_image mrt_key0_image;
    rdma_hw_image mrt_key1_image;
    rdma_hw_image mrt_key2_image;
    rdma_hw_image srqc_image;
    rdma_hw_image ceqc_image;
    rdma_hw_image aeqc_image;

    phase.raise_objection(this);
    registry = rdma_codec_registry::type_id::create("body_registry");
    registry.clear();
    status = rdma_xtr_v1_register_context_body_codecs(registry);
    expect_ok("BODY_REGISTER", status);
    check_registry_contract(registry);

`define BODY_LOOKUP(VAR, KIND, OBJECT_TYPE, VARIANT, OPCODE, LABEL) \
    status = registry.lookup(body_key(KIND, OBJECT_TYPE, VARIANT, OPCODE), VAR); \
    expect_ok(LABEL, status); \
    if (VAR == null) `uvm_fatal(LABEL, "registered codec lookup returned null")
    `BODY_LOOKUP(cqc_codec, RDMA_IMAGE_CQC, "cqc", "create",
                 XTR_V1_OP_CQC_CREATE, "LOOKUP_CQC")
    `BODY_LOOKUP(mrt_key_codec, RDMA_IMAGE_MRT, "mrt", "key_alloc",
                 XTR_V1_OP_KEY_ALLOC, "LOOKUP_MRT_KEY")
    `BODY_LOOKUP(mrt_register_codec, RDMA_IMAGE_MRT, "mrt", "register",
                 XTR_V1_OP_MR_REGISTER, "LOOKUP_MRT_REGISTER")
    `BODY_LOOKUP(srqc_codec, RDMA_IMAGE_SRQC, "srqc", "create",
                 XTR_V1_OP_SRFQC_CREATE, "LOOKUP_SRQC")
    `BODY_LOOKUP(ceqc_codec, RDMA_IMAGE_CEQC, "ceqc", "create",
                 XTR_V1_OP_CEQC_CREATE, "LOOKUP_CEQC")
    `BODY_LOOKUP(aeqc_codec, RDMA_IMAGE_AEQC, "aeqc", "create",
                 XTR_V1_OP_AEQC_CREATE, "LOOKUP_AEQC")
`undef BODY_LOOKUP

    if (!rdma_xtr_v1_golden_reader::read_all(
          "../hw/xtr_v1/golden_vectors/context.hex", cases, error))
      `uvm_fatal("BODY_GOLDEN_READ", error)

    cqc_golden = require_golden(cases,
                                "cqc_create_body_boundary");
    mrt0_golden = require_golden(cases, "mrt_register_pbl0_boundary");
    mrt1_golden = require_golden(cases, "mrt_register_pbl1_boundary");
    mrt2_golden = require_golden(cases, "mrt_register_pbl2_boundary");
    mrt_key0_golden = require_golden(cases, "mrt_key_alloc_pbl0_boundary");
    mrt_key1_golden = require_golden(cases, "mrt_key_alloc_pbl1_boundary");
    mrt_key2_golden = require_golden(cases, "mrt_key_alloc_pbl2_boundary");
    srqc_golden = require_golden(cases, "srqc_create_body_boundary");
    ceqc_golden = require_golden(cases, "ceqc_create_body_boundary");
    aeqc_golden = require_golden(cases, "aeqc_create_body_boundary");
    if (cqc_golden == null || mrt0_golden == null ||
        mrt1_golden == null || mrt2_golden == null ||
        mrt_key0_golden == null || mrt_key1_golden == null ||
        mrt_key2_golden == null || srqc_golden == null ||
        ceqc_golden == null || aeqc_golden == null)
      `uvm_fatal("BODY_GOLDEN_REQUIRED",
                 "one or more required golden cases are unavailable")

    cqc = make_cqc();
    mrt0 = make_mrt("mrt_pbl0", RDMA_MR_PBL0);
    mrt1 = make_mrt("mrt_pbl1", RDMA_MR_PBL1);
    mrt2 = make_mrt("mrt_pbl2", RDMA_MR_PBL2);
    srqc = make_srqc();
    ceqc = make_ceqc();
    aeqc = make_aeqc();

    check_golden_roundtrip("CQC_GOLDEN", cqc_codec, cqc, cqc_golden,
                           RDMA_IMAGE_CQC, cqc.cq_h.generation, cqc_image);
    check_golden_roundtrip("MRT_REGISTER_PBL0_GOLDEN", mrt_register_codec,
                           mrt0, mrt0_golden, RDMA_IMAGE_MRT,
                           mrt0.mr_h.generation, mrt0_image);
    check_golden_roundtrip("MRT_REGISTER_PBL1_GOLDEN", mrt_register_codec,
                           mrt1, mrt1_golden, RDMA_IMAGE_MRT,
                           mrt1.mr_h.generation, mrt1_image);
    check_golden_roundtrip("MRT_REGISTER_PBL2_GOLDEN", mrt_register_codec,
                           mrt2, mrt2_golden, RDMA_IMAGE_MRT,
                           mrt2.mr_h.generation, mrt2_image);
    check_golden_roundtrip("MRT_KEY_ALLOC_PBL0_GOLDEN", mrt_key_codec, mrt0,
                           mrt_key0_golden, RDMA_IMAGE_MRT,
                           mrt0.mr_h.generation, mrt_key0_image);
    check_golden_roundtrip("MRT_KEY_ALLOC_PBL1_GOLDEN", mrt_key_codec, mrt1,
                           mrt_key1_golden, RDMA_IMAGE_MRT,
                           mrt1.mr_h.generation, mrt_key1_image);
    check_golden_roundtrip("MRT_KEY_ALLOC_PBL2_GOLDEN", mrt_key_codec, mrt2,
                           mrt_key2_golden, RDMA_IMAGE_MRT,
                           mrt2.mr_h.generation, mrt_key2_image);
    check_golden_roundtrip("SRQC_GOLDEN", srqc_codec, srqc, srqc_golden,
                           RDMA_IMAGE_SRQC, srqc.srq_h.generation,
                           srqc_image);
    check_golden_roundtrip("CEQC_GOLDEN", ceqc_codec, ceqc, ceqc_golden,
                           RDMA_IMAGE_CEQC, ceqc.ceq_h.generation,
                           ceqc_image);
    check_golden_roundtrip("AEQC_GOLDEN", aeqc_codec, aeqc, aeqc_golden,
                           RDMA_IMAGE_AEQC, aeqc.aeq_h.generation,
                           aeqc_image);

    check_zero_stag_ambiguity(mrt_key_codec, mrt_register_codec);
    check_cqc_coordinates(cqc_codec);
    check_mrt_pbl1_coordinates(mrt_register_codec);
    check_srqc_coordinates(srqc_codec);
    check_eq_coordinates(ceqc_codec, aeqc_codec);

    check_metadata_failures(cqc_codec, cqc_image);
    check_cqc_negatives(cqc_codec, cqc, cqc_image);
    check_mrt_negatives(mrt_key_codec, mrt_register_codec, mrt0, mrt1, mrt2,
                        mrt_key0_image, mrt0_image, mrt1_image, mrt2_image);
    check_srqc_negatives(srqc_codec, srqc, srqc_image);
    check_eq_negatives(ceqc_codec, aeqc_codec, ceqc, aeqc,
                       ceqc_image, aeqc_image);
    check_ceqc_next_invalid(ceqc_codec);
    check_aeqc_next_invalid(aeqc_codec);

    check_reserved_qwords("CQC", cqc_codec, cqc_image, RDMA_IMAGE_CQC,
                          XTR_V1_OP_CQC_CREATE, RDMA_MR_PBL0);
    check_reserved_qwords("MRT_KEY_PBL0", mrt_key_codec, mrt_key0_image,
                          RDMA_IMAGE_MRT, XTR_V1_OP_KEY_ALLOC, RDMA_MR_PBL0);
    check_reserved_qwords("MRT_KEY_PBL1", mrt_key_codec, mrt_key1_image,
                          RDMA_IMAGE_MRT, XTR_V1_OP_KEY_ALLOC, RDMA_MR_PBL1);
    check_reserved_qwords("MRT_KEY_PBL2", mrt_key_codec, mrt_key2_image,
                          RDMA_IMAGE_MRT, XTR_V1_OP_KEY_ALLOC, RDMA_MR_PBL2);
    check_reserved_qwords("MRT_PBL0", mrt_register_codec, mrt0_image,
                          RDMA_IMAGE_MRT, XTR_V1_OP_MR_REGISTER,
                          RDMA_MR_PBL0);
    check_reserved_qwords("MRT_PBL1", mrt_register_codec, mrt1_image,
                          RDMA_IMAGE_MRT, XTR_V1_OP_MR_REGISTER,
                          RDMA_MR_PBL1);
    check_reserved_qwords("MRT_PBL2", mrt_register_codec, mrt2_image,
                          RDMA_IMAGE_MRT, XTR_V1_OP_MR_REGISTER,
                          RDMA_MR_PBL2);
    check_reserved_qwords("SRQC", srqc_codec, srqc_image, RDMA_IMAGE_SRQC,
                          XTR_V1_OP_SRFQC_CREATE, RDMA_MR_PBL0);
    check_reserved_qwords("CEQC", ceqc_codec, ceqc_image, RDMA_IMAGE_CEQC,
                          XTR_V1_OP_CEQC_CREATE, RDMA_MR_PBL0);
    check_reserved_qwords("AEQC", aeqc_codec, aeqc_image, RDMA_IMAGE_AEQC,
                          XTR_V1_OP_AEQC_CREATE, RDMA_MR_PBL0);

    expect_encode_failure("BODY_WRONG_MODEL", cqc_codec, srqc);
    phase.drop_objection(this);
  endtask
endclass
