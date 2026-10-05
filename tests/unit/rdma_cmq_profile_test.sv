// 目录/层次：tests/unit 的 RDMA CMQ hardware profile 单元测试。
// 职责：验证 profile 组合完整性、SQE/CQE/doorbell 编解码与 QPC fixed-VFID。
// 主要依赖：rdma_model_pkg/rdma_codec_pkg 中的真实 profile/body/image；不连接外部 PCIe 或
// Host-memory 后端。
// 所有权与生命周期：测试在 run_phase 拥有所有 fixture/probe/wrapper；factory override
// 仅在指定故障窗口 arm，objection 结束前会恢复可观测状态。

// 设计说明：profile probe 仅暴露受保护依赖的定点清空入口，
// 让 validate_profile() 的每个缺失 codec/registry 分支可独立验证而不复制实现。
class rdma_hw_cmq_profile_probe
    extends rdma_hw_cmq_hw_profile;
  `uvm_object_utils(rdma_hw_cmq_profile_probe)

  // 功能：构造可从测试中精确清空 protected codec/registry 的 production-profile 探针。
  // 输入/输出及副作用：name 透传给 production profile；基类仍正常构造/注册所有 child。
  // 失败/边界：探针不自动注入故障；只能用于后续 validate_profile() 的独立缺失分支。
  function new(string name = "rdma_hw_cmq_profile_probe");
    super.new(name);
  endfunction

  // 功能：将 request_composer 置 null，注入 profile 请求编码器未初始化分支。
  // 输入/输出及副作用：无参数或返回值；丢弃 probe 的 protected child 句柄，不修改其他 codec。
  // 失败/边界：重复调用幂等；无恢复入口，该 probe 随后只能用于失败断言。
  function void clear_request_composer();
    request_composer = null;
  endfunction

  // 功能：将 completion_codec 置 null，注入 CQE 解码依赖缺失分支。
  // 输入/输出及副作用：无参数或返回值；只修改 probe 拥有的 completion_codec 句柄。
  // 失败/边界：重复调用幂等；清空后 validate_profile() 必须返回 INVALID_STATE。
  function void clear_completion_codec();
    completion_codec = null;
  endfunction

  // 功能：将 error_codec 置 null，注入 command ecode 转 operation status 的依赖缺失分支。
  // 输入/输出及副作用：无参数或返回值；只清除 probe 拥有的 error_codec 句柄。
  // 失败/边界：重复调用幂等；清空后不得继续 inspect_cqe()。
  function void clear_error_codec();
    error_codec = null;
  endfunction

  // 功能：将 doorbell_codecs registry 置 null，注入 profile registry 未构造分支。
  // 输入/输出及副作用：无参数或返回值；清除 probe 对 registry 的拥有句柄。
  // 失败/边界：重复调用幂等；该 probe 清空后不能再调用 clear_doorbell_defaults()。
  function void clear_doorbell_registry();
    doorbell_codecs = null;
  endfunction

  // 功能：保留 registry 对象但删除其所有 default codec，注入“registry 存在但不完整”分支。
  // 输入/输出及副作用：无参数或返回值；调用 doorbell_codecs.clear() 修改 probe 拥有的 registry。
  // 失败/边界：doorbell_codecs 必须非 null；清空后 validate_profile() 必须拒绝首个缺失 variant。
  function void clear_doorbell_defaults();
    doorbell_codecs.clear();
  endfunction

endclass

// 设计说明：该 registry 通过一次性预注册相同 key 制造 constructor-time 冲突，
// 用真实 register_codec() 路径验证 profile 不会忽略默认 doorbell codec 注册失败。
class rdma_hw_cmq_conflicted_doorbell_registry
    extends rdma_hw_doorbell_codec_registry;
  `uvm_object_utils(rdma_hw_cmq_conflicted_doorbell_registry)

  local static bit arm_conflict;
  local static bit conflict_seeded;

  // 功能：构造 doorbell registry，并在静态 arm 时预先占用 rdma/cmq_sq key 制造默认注册冲突。
  // 输入/输出及副作用：name 透传给 registry；arm 时消费 arm_conflict，直接 new 一个
  // cmq_sq codec，调用 register_codec() 并仅在 OK 后设 conflict_seeded=1。
  // 失败/边界：未 arm 时不注入冲突；fixture 预注册自身失败时发布
  // PROFILE_REGISTRY_FIXTURE fatal，避免把无效前置条件误当生产结果。
  function new(
    string name = "rdma_hw_cmq_conflicted_doorbell_registry"
  );
    rdma_codec_key conflict_key;
    rdma_hw_doorbell_codec conflict_codec;
    rdma_status status;

    super.new(name);
    if (arm_conflict) begin
      arm_conflict = 1'b0;
      conflict_seeded = 1'b0;
      conflict_key = '{hw_version:"rdma",
                       image_kind:RDMA_IMAGE_DOORBELL,
                       object_type:"doorbell", variant:"cmq_sq",
                       opcode:8'h00};
      conflict_codec = new("pre_registered_cmq_sq", "cmq_sq");
      status = register_codec(conflict_key, conflict_codec);
      if (status == null || !status.ok())
        `uvm_fatal("PROFILE_REGISTRY_FIXTURE",
                   "failed to seed CMQ doorbell registration collision")
      else
        conflict_seeded = 1'b1;
    end
  endfunction

  // 功能：设置一次性静态开关，使下一个 conflicted registry 实例预注册 cmq_sq key。
  // 输入/输出及副作用：无参数或返回值；将 arm_conflict 置 1、conflict_seeded 清 0，
  // 不立即创建 registry 或 codec。
  // 失败/边界：重复 arm 合并为一次待消费故障；开关在下一实例构造时自动清除。
  static function void arm_next_instance();
    arm_conflict = 1'b1;
    conflict_seeded = 1'b0;
  endfunction

  // 功能：查询上一个已 arm 实例是否成功建立 cmq_sq 预注册冲突。
  // 输入/输出及副作用：无参数；返回静态 conflict_seeded 位，不修改 registry 或开关。
  // 失败/边界：未 arm、实例尚未构造或最近一次预注册未完成时返回 0。
  static function bit seeded_collision();
    return conflict_seeded;
  endfunction
endclass

// 设计说明：主 test 组合真实 profile、typed body 和故障 probe，冻结硬件编解码兼容性。
class rdma_cmq_profile_test extends uvm_test;
  `uvm_component_utils(rdma_cmq_profile_test)

  localparam longint unsigned TEST_FUNCTION_UID =
    64'h1122_3344_5566_7788;
  localparam int unsigned TEST_GENERATION = 32'd7;

  // 功能：构造 CMQ profile 单元测试组件，fixture 在 run_phase 内按场景创建。
  // 输入/输出及副作用：name/parent 透传给 uvm_test；构造阶段不安装 factory override/callback，不发布报告。
  // 失败/边界：parent 可为 null 作顶层 test；所有 objection 和故障窗口都由 run_phase 配对管理。
  function new(string name = "rdma_cmq_profile_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：断言 profile 返回非空 status，且 code 与指定分支期望一致。
  // 输入/输出及副作用：label 作 report ID，status/expected 只读；不匹配时发布 UVM_ERROR，
  // 不修改 status 或 DUT。
  // 失败/边界：status==null 单独报错；code 不等时附带 expected/actual 名称与完整 status 文本；
  // helper 不中止调用者的后续断言。
  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null)
      `uvm_error(label, "profile returned a null status")
    else if (status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)", expected.name(),
                           status.code.name(), status.convert2string()))
  endfunction

  // 功能：创建 profile 场景共用的固定 Function incarnation handle fixture。
  // 输入/输出及副作用：name 选择 UVM 实例名；返回 factory-created Function handle，
  // UID=TEST_FUNCTION_UID、global object ID=32'h1234、generation=TEST_GENERATION。
  // 失败/边界：依赖标准 typed factory 返回正确类型；本 fixture 不登记真实 Function 资源或 reset epoch。
  function automatic rdma_function_handle make_function(string name);
    rdma_function_handle function_h;
    function_h = rdma_function_handle::type_id::create(name);
    function_h.function_uid = TEST_FUNCTION_UID;
    function_h.object_id = 32'h1234;
    function_h.generation = TEST_GENERATION;
    return function_h;
  endfunction

  // 功能：创建归属测试 Function incarnation 的指定 resource-kind/object-ID handle fixture。
  // 输入/输出及副作用：name/kind/object_id 为输入；返回 factory-created base handle，
  // UID/generation 固定为测试常量，调用方拥有 fixture。
  // 失败/边界：helper 不约束 kind 与 object_id，因此可构造非法测试输入；不创建对应真实资源。
  function automatic rdma_handle make_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle handle;
    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.function_uid = TEST_FUNCTION_UID;
    handle.object_id = object_id;
    handle.generation = TEST_GENERATION;
    return handle;
  endfunction

  // 功能：创建一条有效 rdma/CQC_DELETE command fixture，并把驱动要求的完整
  //   CQC context 放入 typed body，避免测试把“仅 CQN”误当成可发送请求。
  // 输入/输出及副作用：name 派生 context/handle 名；返回 context 拥有自己的
  //   CQ/CEQ/page/ring 节点，句柄默认使用本 test 的 Function UID/generation。
  // 失败/边界：function_h==null 仍由调用方用于负例；context 的校验失败由 profile
  //   compose_sqe() 报告，本 helper 不访问外部资源或 Host memory。
  function automatic rdma_cqc_model make_cqc_delete_context(string name);
    rdma_cqc_model cqc_context;

    cqc_context = rdma_cqc_model::type_id::create({name, "_context"});
    cqc_context.cq_h = make_handle({name, "_cq"}, RDMA_RESOURCE_CQ,
                               21'h12345);
    cqc_context.ceq_h = make_handle({name, "_ceq"}, RDMA_RESOURCE_CEQ,
                                12'h155);
    cqc_context.state = RDMA_CONTEXT_VALID;
    cqc_context.depth = 1024;
    cqc_context.cqe_size_bytes = 64;
    cqc_context.threshold = 5;
    cqc_context.page_layout.mode = RDMA_OBJECT_HUGE_2M;
    cqc_context.page_layout.sd_base.value = 64'h1b23_4567_89ab_c000;
    cqc_context.page_layout.current_base.value = 64'h3c34_5678_9abc_d000;
    cqc_context.page_layout.current_valid = 1'b1;
    cqc_context.page_layout.next_base.value = 64'h5a12_3456_789a_b000;
    cqc_context.page_layout.next_valid = 1'b1;
    cqc_context.producer.index = 23'h155;
    cqc_context.producer.wrap = 1'b0;
    cqc_context.consumer.index = 23'h2aa;
    cqc_context.consumer.wrap = 1'b1;
    cqc_context.urc_enable = 1'b0;
    cqc_context.load_ci_done = 1'b0;
    cqc_context.last_arm_sequence = 2'd1;
    cqc_context.arm_sequence = 2'd2;
    cqc_context.arm_state = 2'd1;
    cqc_context.shadow_backing.value = 64'h4d45_6789_abcd_efc0;
    return cqc_context;
  endfunction

  // 功能：创建一条有效 rdma/CQC_DELETE command fixture，并把驱动要求的完整
  //   CQC context 放入 typed body，避免测试把“仅 CQN”误当成可发送请求。
  // 输入/输出及副作用：name 派生 command/key/body/CQ 名，function_h 作非拥有输入；
  //   返回拥有 key/body/context 的 command，设置 VFID override=1/use_vfid=11'h345 与 timeout=100。
  // 失败/边界：function_h==null 可用于无效场景且不在 helper 内报错；所有 factory 依赖由测试环境保证。
  function automatic rdma_cmq_command_desc make_command(
    string name,
    rdma_function_handle function_h
  );
    rdma_cmq_command_desc command;
    rdma_cmq_opcode_key key;
    rdma_hw_cqc_delete_body body;

    key = rdma_cmq_opcode_key::type_id::create({name, "_key"});
    key.profile_name = "rdma";
    key.opcode = RDMA_OP_CQC_DELETE;
    key.variant = "delete";
    body = rdma_hw_cqc_delete_body::type_id::create(
      {name, "_body"});
    body.cqc_context = make_cqc_delete_context(name);
    if (function_h != null) begin
      body.cqc_context.cq_h.function_uid = function_h.function_uid;
      body.cqc_context.cq_h.generation = function_h.generation;
      body.cqc_context.ceq_h.function_uid = function_h.function_uid;
      body.cqc_context.ceq_h.generation = function_h.generation;
    end
    command = rdma_cmq_command_desc::type_id::create(name);
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = body;
    command.qpc_signature_source = null;
    command.vfid_override = 1'b1;
    command.use_vfid = 11'h345;
    command.timeout = 100;
    return command;
  endfunction

  // 功能：创建 sequence=37 对应 SQ index=5/wrap=1 的 64B-aligned CMQ slot fixture。
  // 输入/输出及副作用：name/function_h/cmq_h 为输入；返回 backing=0x40000000、
  // relative_offset=320 的 slot，不分配或写入真实 backing memory。
  // 失败/边界：句柄为 null/错误 kind 时仍返回 fixture 供拒绝测试；helper 本身不调用 validate()。
  function automatic rdma_cmq_slot_context make_slot(
    string name,
    rdma_function_handle function_h,
    rdma_handle cmq_h
  );
    rdma_cmq_slot_context slot;
    slot = rdma_cmq_slot_context::type_id::create(name);
    slot.function_h = function_h;
    slot.cmq_h = cmq_h;
    slot.backing_addr.value = 64'h0000_0000_4000_0000;
    slot.relative_offset = 64'd320;
    slot.slot_sequence = 64'd37;
    slot.sq_index = 5;
    slot.sq_wrap = 1'b1;
    return slot;
  endfunction

  // 功能：按 big-endian byte 顺序从 image 提取指定 64-bit qword，供精确字段断言。
  // 输入/输出及副作用：image 只读，qword_index 乘 8 定位起始 byte；返回按索引顺序组合的 64 位值。
  // 失败/边界：helper 不检查 null 或边界；调用方必须保证 image.bytes 至少覆盖 qword_index*8+7。
  function automatic bit [63:0] get_qword(
    rdma_hw_image image,
    int unsigned qword_index
  );
    bit [63:0] value;
    int unsigned base;
    value = '0;
    base = qword_index * 8;
    for (int unsigned i = 0; i < 8; i++)
      value = {value[55:0], image.bytes[base + i]};
    return value;
  endfunction

  // 功能：按 big-endian byte 顺序把 64-bit value 写入 image 的指定 qword，用于构造 CQE 和负向 fixture。
  // 输入/输出及副作用：image 为测试拥有的 inout 对象，qword_index/value 为输入；
  // 覆盖 bytes[index*8 +: 8] 而不更新 image metadata。
  // 失败/边界：无 status/边界检查；调用方必须保证 image 非 null 且 byte array 足够长，否则会越界。
  function automatic void set_qword(
    rdma_hw_image image,
    int unsigned qword_index,
    bit [63:0] value
  );
    int unsigned base;
    base = qword_index * 8;
    for (int unsigned i = 0; i < 8; i++)
      image.bytes[base + i] = value[63 - (i * 8) -: 8];
  endfunction

  // 功能：创建 hardware image 的 UVM deep-copy fixture，供单字段变异而不污染 baseline。
  // 输入/输出及副作用：source 只读，name 作新对象名；factory-create result 后调用 copy(source)，
  // 返回调用方拥有的 image，不修改 source。
  // 失败/边界：source==null 或 factory/copy 失败可触发 UVM 底层错误/fatal；此测试 helper 不是 nonfatal 生产边界。
  function automatic rdma_hw_image clone_image(
    rdma_hw_image source,
    string name
  );
    rdma_hw_image result;
    result = rdma_hw_image::type_id::create(name);
    result.copy(source);
    return result;
  endfunction

  // 功能：比较两个 hardware image 的全部公开 metadata、bytes 和 field_summary 值。
  // 输入/输出及副作用：lhs/rhs 只读；字段、数组长度和每个元素全部一致返回 1，不修改 image。
  // 失败/边界：null、数组长度不同或任一 metadata/byte/summary 不同时立即返回 0。
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
      if (lhs.bytes[i] != rhs.bytes[i])
        return 1'b0;
    foreach (lhs.field_summary[i])
      if (lhs.field_summary[i] != rhs.field_summary[i])
        return 1'b0;
    return 1'b1;
  endfunction

  // 功能：构造完整 64B big-endian CMQ CQE fixture，在 qword0 填入 owner/wrap/index/opcode/ecode。
  // 输入/输出及副作用：五个硬件字段为输入；返回 NONE-target CQE image，
  // bytes[8:63] 填索引 pattern 作 payload，调用方拥有 fixture。
  // 失败/边界：输入位宽已限定范围；typed factory 必须可用，set_qword() 依赖预先创建的 64 字节数组。
  function automatic rdma_hw_image make_cqe(
    bit owner,
    bit [7:0] opcode,
    bit [7:0] command_ecode,
    bit [4:0] wqe_index,
    bit wrap
  );
    rdma_hw_image image;
    bit [63:0] qword0;
    image = rdma_hw_image::type_id::create("profile_cqe");
    repeat (64) image.bytes.push_back(8'h00);
    image.length = 64;
    image.alignment = 64;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_CMQ_CQE;
    image.hardware_version = RDMA_HW_VERSION;
    image.function_generation = 0;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;
    qword0 = '0;
    qword0[63] = owner;
    qword0[45] = wrap;
    qword0[44:40] = wqe_index;
    qword0[39:32] = opcode;
    qword0[31:24] = command_ecode;
    set_qword(image, 0, qword0);
    for (int unsigned i = 8; i < 64; i++)
      image.bytes[i] = i[7:0];
    return image;
  endfunction

  // 功能：验证健康 RDMA profile、五类缺失依赖以及默认 doorbell 注册冲突的诊断契约。
  // 输入/输出及副作用：无参数；创建本地 profile/probe，并安装一次性 registry factory
  //   override 注入 key 冲突；通过 UVM report 发布断言结果，不执行硬件 I/O。
  // 失败/边界：缺失 child/default 必须返回 INVALID_STATE；冲突必须保留精确注册消息，
  //   且一次性故障消费后新 profile 必须恢复为有效状态。
  function automatic void check_profile_validation();
    rdma_hw_cmq_hw_profile profile;
    rdma_hw_cmq_hw_profile failed_registration_profile;
    rdma_hw_cmq_profile_probe probe;
    uvm_factory factory;
    rdma_status status;
    string expected_message;

    profile = rdma_hw_cmq_hw_profile::type_id::create("profile");
    if (profile.profile_name() != "rdma")
      `uvm_error("PROFILE_NAME", "rdma profile reported a wrong name")
    expect_status("PROFILE_VALID", profile.validate_profile(), RDMA_SC_OK);

    probe = rdma_hw_cmq_profile_probe::type_id::create(
      "missing_request_composer");
    probe.clear_request_composer();
    expect_status("PROFILE_MISSING_REQUEST", probe.validate_profile(),
                  RDMA_SC_INVALID_STATE);
    probe = rdma_hw_cmq_profile_probe::type_id::create(
      "missing_completion_codec");
    probe.clear_completion_codec();
    expect_status("PROFILE_MISSING_COMPLETION", probe.validate_profile(),
                  RDMA_SC_INVALID_STATE);
    probe = rdma_hw_cmq_profile_probe::type_id::create(
      "missing_error_codec");
    probe.clear_error_codec();
    expect_status("PROFILE_MISSING_ERROR", probe.validate_profile(),
                  RDMA_SC_INVALID_STATE);
    probe = rdma_hw_cmq_profile_probe::type_id::create(
      "missing_doorbell_registry");
    probe.clear_doorbell_registry();
    expect_status("PROFILE_MISSING_DOORBELL_REGISTRY",
                  probe.validate_profile(), RDMA_SC_INVALID_STATE);
    probe = rdma_hw_cmq_profile_probe::type_id::create(
      "missing_doorbell_defaults");
    probe.clear_doorbell_defaults();
    expect_status("PROFILE_MISSING_DOORBELLS", probe.validate_profile(),
                  RDMA_SC_INVALID_STATE);
    factory = uvm_factory::get();
    factory.set_type_override_by_type(
      rdma_hw_doorbell_codec_registry::get_type(),
      rdma_hw_cmq_conflicted_doorbell_registry::get_type()
    );
    rdma_hw_cmq_conflicted_doorbell_registry::arm_next_instance();
    failed_registration_profile =
      rdma_hw_cmq_hw_profile::type_id::create(
        "failed_doorbell_registration");
    if (!rdma_hw_cmq_conflicted_doorbell_registry::seeded_collision())
      `uvm_error("PROFILE_ARM_REGISTRATION_FAILURE",
                 "factory override did not seed the intended collision")
    status = failed_registration_profile.validate_profile();
    expect_status("PROFILE_FAILED_DOORBELL_REGISTRATION", status,
                  RDMA_SC_INVALID_STATE);
    expected_message = {
      "rdma doorbell codec key already registered: ",
      $sformatf("rdma|%0d|doorbell|cmq_sq|00", RDMA_IMAGE_DOORBELL)
    };
    if (status != null && status.message != expected_message)
      `uvm_error("PROFILE_FAILED_DOORBELL_REGISTRATION",
                 {"profile did not preserve register_defaults failure: ",
                  status.message})

    profile = rdma_hw_cmq_hw_profile::type_id::create(
      "profile_after_registration_failure");
    expect_status("PROFILE_AFTER_REGISTRATION_FAILURE",
                  profile.validate_profile(), RDMA_SC_OK);
  endfunction

  // 功能：check_driver_034_registry_contract 验证 0.1.34 的完整 opcode
  //   连续表、描述符自洽性以及未知 opcode 的拒绝行为。
  // 输入/输出及副作用：只读取静态 registry，使用 UVM_ERROR 暴露漂移，
  //   不修改 profile、CMQ ring 或任何外部资源。
  // 失败/边界：缺少任一 0x00..0x48 项、lookup 返回空快照或 0xff 被接受时失败。
  function automatic void check_driver_034_registry_contract();
    bit [7:0] supported[$];
    rdma_cmq_opcode_descriptor descriptor;
    rdma_status status;

    status = rdma_cmq_codec_registry::validate();
    expect_status("CMQ034_REGISTRY_VALIDATE", status, RDMA_SC_OK);
    rdma_cmq_codec_registry::list_supported(supported);
    if (supported.size() != 73)
      `uvm_error("CMQ034_REGISTRY_COUNT",
                 $sformatf("expected 73 opcodes, got %0d", supported.size()))
    foreach (supported[i])
      if (supported[i] != i[7:0])
        `uvm_error("CMQ034_REGISTRY_ORDER",
                   $sformatf("opcode[%0d] is 0x%02x", i, supported[i]))
    status = rdma_cmq_codec_registry::lookup(8'hff, descriptor);
    expect_status("CMQ034_UNKNOWN_LOOKUP", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);
    if (descriptor != null)
      `uvm_error("CMQ034_UNKNOWN_LOOKUP", "unknown opcode returned a descriptor")

    // OCC_FLUSH 与 TQ_FLUSH 的 body 不携带 Function generation；profile 的
    // compose_sqe 会在最终定址 SQE 上恢复调用方 generation，但 registry 仍须
    // 对外公开同一 generationless 判定，避免不同调用者形成两套规则。
    if (!rdma_cmq_codec_registry::is_generationless(RDMA_OP_OCC_FLUSH))
      `uvm_error("CMQ034_GENERATIONLESS_OCC",
                 "OCC_FLUSH is missing from generationless registry")
    if (!rdma_cmq_codec_registry::is_generationless(RDMA_OP_TQ_FLUSH))
      `uvm_error("CMQ034_GENERATIONLESS_TQ",
                 "TQ_FLUSH is missing from generationless registry")
  endfunction

  // 功能：验证 CQC_DELETE compose 的 SQE 字节/metadata、期望响应、输入不可变和输出分离。
  // 输入/输出及副作用：无参数；构造本地 command/slot，调用真实 profile 两次并变异
  //   首次输出检查别名；仅产生 UVM report，不写 Host memory 或 doorbell。
  // 失败/边界：错误 profile、高位 opcode、无效 VFID、body 不匹配、未实现 opcode 和
  //   backing 地址溢出必须返回各自错误码，并把预置 sqe/expected 输出清空。
  function automatic void check_compose_sqe();
    rdma_hw_cmq_hw_profile profile;
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_cmq_command_desc command;
    rdma_cmq_command_desc command_snapshot;
    rdma_cmq_slot_context slot;
    rdma_cmq_slot_context slot_snapshot;
    rdma_hw_cqc_delete_body body;
    rdma_hw_cqc_delete_body snapshot_body;
    rdma_hw_object_id_command_body generic_body;
    rdma_hw_image context_image;
    rdma_hw_cqc_create_body_codec context_codec;
    rdma_status context_status;
    rdma_hw_image sqe;
    rdma_hw_image second_sqe;
    rdma_cmq_expected_response expected;
    rdma_cmq_expected_response second_expected;
    rdma_status status;
    bit [63:0] qword0;

    profile = rdma_hw_cmq_hw_profile::type_id::create(
      "compose_profile");
    function_h = make_function("compose_function");
    cmq_h = make_handle("compose_cmq", RDMA_RESOURCE_CMQ, 32'h55);
    command = make_command("compose_command", function_h);
    slot = make_slot("compose_slot", function_h, cmq_h);
    command_snapshot = rdma_cmq_command_desc::type_id::create(
      "command_snapshot");
    command_snapshot.copy(command);
    slot_snapshot = rdma_cmq_slot_context::type_id::create("slot_snapshot");
    slot_snapshot.copy(slot);

    sqe = null;
    expected = null;
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_STATUS", status, RDMA_SC_OK);
    if (sqe == null || expected == null) begin
      `uvm_error("COMPOSE_OUTPUT", "successful compose published null")
      return;
    end
    qword0 = get_qword(sqe, 0);
    if (sqe.length != 64 || sqe.bytes.size() != 64 ||
        sqe.alignment != 64 || sqe.endian != RDMA_ENDIAN_BIG ||
        sqe.image_kind != RDMA_IMAGE_CMQ_SQE ||
        sqe.hardware_version != RDMA_HW_VERSION ||
        sqe.function_generation != TEST_GENERATION ||
        sqe.write_target_kind != RDMA_HW_TARGET_BACKING ||
        sqe.backing_target.value != 64'h0000_0000_4000_0140 ||
        sqe.hmc_target.value != 0 || sqe.bar_target.value != 0)
      `uvm_error("COMPOSE_METADATA", "composed SQE metadata is wrong")
    if (qword0[63] != !slot.sq_wrap || qword0[59] != 1'b1 ||
        qword0[58:48] != 11'h345 || qword0[45] != slot.sq_wrap ||
        qword0[44:40] != slot.sq_index[4:0] ||
        qword0[39:32] != RDMA_OP_CQC_DELETE ||
        qword0[20:0] != 21'h12345)
      `uvm_error("COMPOSE_FIELDS", "composed SQE envelope/body is wrong")

    if (!$cast(body, command.body) ||
        !$cast(snapshot_body, command_snapshot.body) ||
        body.cqc_context == null || snapshot_body.cqc_context == null) begin
      `uvm_error("COMPOSE_TYPED_BODY", "CQC_DELETE body lost its typed context")
      return;
    end
    else begin
      context_codec = new("compose_context_codec");
      context_image = null;
      context_status = context_codec.encode(body.cqc_context, context_image);
      if (context_status == null || !context_status.ok() ||
          context_image == null || context_image.bytes.size() != 64)
        `uvm_error("COMPOSE_CONTEXT_IMAGE", "CQC context fixture did not encode")
      else begin
        for (int unsigned i = 0; i < 56; i++) begin
          if (sqe.bytes[8 + i] != context_image.bytes[8 + i]) begin
            `uvm_error("COMPOSE_CONTEXT_BYTES",
                       $sformatf("byte[%0d] expected %02x, got %02x", i,
                                 context_image.bytes[8 + i], sqe.bytes[8 + i]))
            break;
          end
        end
        if (sqe.bytes[63] != context_image.bytes[63])
          `uvm_error("COMPOSE_CONTEXT_LAST_BYTE",
                     "CQC_DELETE did not copy context byte 63")
      end
    end
    if (expected.hardware_opcode != RDMA_OP_CQC_DELETE ||
        expected.variant != "delete")
      `uvm_error("COMPOSE_EXPECTED", "expected response is wrong")

    if (command.function_h != function_h ||
        command.function_h.function_uid !=
          command_snapshot.function_h.function_uid ||
        command.function_h.object_id !=
          command_snapshot.function_h.object_id ||
        command.function_h.generation !=
          command_snapshot.function_h.generation ||
        command.opcode_key.profile_name !=
          command_snapshot.opcode_key.profile_name ||
        command.opcode_key.opcode != command_snapshot.opcode_key.opcode ||
        command.opcode_key.variant != command_snapshot.opcode_key.variant ||
        command.vfid_override != command_snapshot.vfid_override ||
        command.use_vfid != command_snapshot.use_vfid ||
        command.timeout != command_snapshot.timeout ||
        body.cqc_context.cq_h.kind != snapshot_body.cqc_context.cq_h.kind ||
        body.cqc_context.cq_h.function_uid !=
          snapshot_body.cqc_context.cq_h.function_uid ||
        body.cqc_context.cq_h.object_id !=
          snapshot_body.cqc_context.cq_h.object_id ||
        body.cqc_context.cq_h.generation !=
          snapshot_body.cqc_context.cq_h.generation ||
        body.cqc_context == snapshot_body.cqc_context)
      `uvm_error("COMPOSE_COMMAND_IMMUTABLE", "compose mutated command")
    if (slot.function_h != function_h || slot.cmq_h != cmq_h ||
        slot.backing_addr.value != slot_snapshot.backing_addr.value ||
        slot.relative_offset != slot_snapshot.relative_offset ||
        slot.slot_sequence != slot_snapshot.slot_sequence ||
        slot.sq_index != slot_snapshot.sq_index ||
        slot.sq_wrap != slot_snapshot.sq_wrap)
      `uvm_error("COMPOSE_SLOT_IMMUTABLE", "compose mutated slot")

    sqe.bytes[0] ^= 8'hff;
    expected.variant = "mutated";
    second_sqe = null;
    second_expected = null;
    status = profile.compose_sqe(command, slot, second_sqe, second_expected);
    expect_status("COMPOSE_DETACHED_STATUS", status, RDMA_SC_OK);
    if (second_sqe == null || second_expected == null ||
        second_sqe == sqe || second_expected == expected ||
        get_qword(second_sqe, 0)[63] != !slot.sq_wrap ||
        second_expected.variant != "delete")
      `uvm_error("COMPOSE_DETACHED", "compose outputs alias profile state")

    sqe = rdma_hw_image::type_id::create("stale_bad_profile_sqe");
    expected = rdma_cmq_expected_response::type_id::create(
      "stale_bad_profile_expected");
    command.opcode_key.profile_name = "other_profile";
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_OTHER_PROFILE", status, RDMA_SC_INVALID_ARGUMENT);
    if (sqe != null || expected != null)
      `uvm_error("COMPOSE_OTHER_PROFILE", "failure published outputs")
    command.opcode_key.profile_name = "rdma";

    command.opcode_key.opcode = 32'h0100_000e;
    sqe = rdma_hw_image::type_id::create("stale_high_opcode_sqe");
    expected = rdma_cmq_expected_response::type_id::create(
      "stale_high_opcode_expected");
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_HIGH_OPCODE", status, RDMA_SC_INVALID_ARGUMENT);
    if (sqe != null || expected != null)
      `uvm_error("COMPOSE_HIGH_OPCODE", "failure published outputs")
    command.opcode_key.opcode = RDMA_OP_CQC_DELETE;

    command.vfid_override = 1'b0;
    sqe = rdma_hw_image::type_id::create("stale_invalid_vfid_sqe");
    expected = rdma_cmq_expected_response::type_id::create(
      "stale_invalid_vfid_expected");
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_INVALID_VFID", status, RDMA_SC_INVALID_ARGUMENT);
    if (sqe != null || expected != null)
      `uvm_error("COMPOSE_INVALID_VFID", "failure published outputs")
    command.vfid_override = 1'b1;

    command.opcode_key.opcode = RDMA_OP_TQ_FLUSH;
    command.opcode_key.variant = "flush";
    sqe = rdma_hw_image::type_id::create("stale_incompatible_body_sqe");
    expected = rdma_cmq_expected_response::type_id::create(
      "stale_incompatible_body_expected");
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_INCOMPATIBLE_BODY", status,
                  RDMA_SC_INVALID_ARGUMENT);
    if (sqe != null || expected != null)
      `uvm_error("COMPOSE_INCOMPATIBLE_BODY", "failure published outputs")
    command.opcode_key.opcode = RDMA_OP_CQC_DELETE;
    command.opcode_key.variant = "delete";

    // CQC_DELETE 不允许退回旧的 generic object-ID body；驱动会从 context
    //   读取 56 bytes，只有 CQN 的旧 fixture 必须在 compose 边界明确拒绝。
    generic_body = rdma_hw_object_id_command_body::type_id::create(
      "generic_cqc_delete_body"
    );
    generic_body.object_h = make_handle(
      "generic_cqc_delete_cq", RDMA_RESOURCE_CQ, 21'h12345
    );
    command.body = generic_body;
    sqe = null;
    expected = null;
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_GENERIC_CQC_DELETE", status,
                  RDMA_SC_INVALID_ARGUMENT);
    if (sqe != null || expected != null)
      `uvm_error("COMPOSE_GENERIC_CQC_DELETE",
                 "generic CQC_DELETE body published an image")
    command.body = body;

    // 已在 driver 中定义但尚无精确 body codec 的命令，必须在 compose
    //   阶段返回 UNSUPPORTED_OPCODE，禁止生成全零假 body。
    command.opcode_key.opcode = RDMA_OP_CEQC_MODIFY;
    command.opcode_key.variant = "modify";
    sqe = null;
    expected = null;
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_UNIMPLEMENTED_034_OPCODE", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);
    if (sqe != null || expected != null)
      `uvm_error("COMPOSE_UNIMPLEMENTED_034_OPCODE",
                 "unsupported body codec published an image")
    command.opcode_key.opcode = RDMA_OP_CQC_DELETE;
    command.opcode_key.variant = "delete";

    slot.backing_addr.value = 64'hffff_ffff_ffff_ffc0;
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_TARGET_OVERFLOW", status,
                  RDMA_SC_DMA_TRANSLATION);
    if (sqe != null || expected != null)
      `uvm_error("COMPOSE_TARGET_OVERFLOW", "failure published outputs")
  endfunction

  // 功能：验证普通 object body 的 generation 隔离，以及 OCC/TQ generationless 编码策略。
  // 输入/输出及副作用：无参数；构造本地 command/slot 快照并调用真实 compose_sqe，
  //   检查 OCC 与空 TQ body 的 qword/metadata/expected 值；只发布 UVM report。
  // 失败/边界：对象句柄代际不匹配必须返回 STALE_GENERATION 且无输出；合法 OCC/TQ
  //   必须编码成功并保持 command、body、slot 和其嵌套值不变。
  function automatic void check_compose_generation_policy();
    rdma_hw_cmq_hw_profile profile;
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_cmq_command_desc command;
    rdma_cmq_command_desc command_snapshot;
    rdma_cmq_opcode_key key;
    rdma_cmq_slot_context slot;
    rdma_cmq_slot_context slot_snapshot;
    rdma_hw_cqc_delete_body cqc_delete_body;
    rdma_hw_occ_flush_body occ_body;
    rdma_hw_occ_flush_body occ_snapshot;
    rdma_hw_cmq_empty_body empty_body;
    rdma_hw_cmq_empty_body empty_snapshot;
    rdma_hw_image sqe;
    rdma_cmq_expected_response expected;
    rdma_status status;
    bit [63:0] qword0;

    profile = rdma_hw_cmq_hw_profile::type_id::create(
      "generation_profile");
    function_h = make_function("generation_function");
    cmq_h = make_handle("generation_cmq", RDMA_RESOURCE_CMQ, 32'h56);
    slot = make_slot("generation_slot", function_h, cmq_h);

    command = make_command("mismatched_generation_command", function_h);
    if (!$cast(cqc_delete_body, command.body) ||
        cqc_delete_body.cqc_context == null ||
        cqc_delete_body.cqc_context.cq_h == null) begin
      `uvm_error("COMPOSE_BODY_GENERATION_SETUP",
                 "typed CQC_DELETE body cast failed")
      return;
    end
    cqc_delete_body.cqc_context.cq_h.generation = TEST_GENERATION + 1;
    sqe = rdma_hw_image::type_id::create("stale_generation_sqe");
    expected = rdma_cmq_expected_response::type_id::create(
      "stale_generation_expected");
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_BODY_GENERATION", status,
                  RDMA_SC_STALE_GENERATION);
    if (sqe != null || expected != null)
      `uvm_error("COMPOSE_BODY_GENERATION",
                 "generation mismatch published outputs")
    if (cqc_delete_body.cqc_context.cq_h.generation != TEST_GENERATION + 1)
      `uvm_error("COMPOSE_BODY_GENERATION",
                 "generation mismatch mutated the command body")

    occ_body = rdma_hw_occ_flush_body::type_id::create(
      "generationless_occ_body");
    occ_body.vf_flush = 1'b1;
    occ_body.qpc = 1'b1;
    occ_body.cqc = 1'b1;
    occ_body.mrt = 1'b1;
    occ_body.pble = 1'b1;
    occ_body.sqrqe = 1'b1;
    occ_body.sgb_irqe = 1'b1;
    occ_body.eirqe = 1'b1;
    occ_body.orqe = 1'b1;
    occ_body.uaqe = 1'b1;
    key = rdma_cmq_opcode_key::type_id::create("occ_flush_key");
    key.profile_name = "rdma";
    key.opcode = RDMA_OP_OCC_FLUSH;
    key.variant = "vf_flush";
    command = rdma_cmq_command_desc::type_id::create("occ_flush_command");
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = occ_body;
    command.qpc_signature_source = null;
    command.vfid_override = 1'b1;
    command.use_vfid = 11'h345;
    command.timeout = 100;
    command_snapshot = rdma_cmq_command_desc::type_id::create(
      "occ_flush_command_snapshot");
    command_snapshot.copy(command);
    if (!$cast(occ_snapshot, command_snapshot.body)) begin
      `uvm_error("COMPOSE_OCC_SETUP", "OCC snapshot body cast failed")
      return;
    end
    slot_snapshot = rdma_cmq_slot_context::type_id::create(
      "occ_flush_slot_snapshot");
    slot_snapshot.copy(slot);

    sqe = null;
    expected = null;
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_OCC_STATUS", status, RDMA_SC_OK);
    if (sqe == null || expected == null) begin
      `uvm_error("COMPOSE_OCC_OUTPUT", "OCC flush published null outputs")
      return;
    end
    qword0 = get_qword(sqe, 0);
    if (sqe.length != 64 || sqe.bytes.size() != 64 ||
        sqe.alignment != 64 || sqe.endian != RDMA_ENDIAN_BIG ||
        sqe.image_kind != RDMA_IMAGE_CMQ_SQE ||
        sqe.hardware_version != RDMA_HW_VERSION ||
        sqe.function_generation != TEST_GENERATION ||
        sqe.write_target_kind != RDMA_HW_TARGET_BACKING ||
        sqe.backing_target.value != 64'h0000_0000_4000_0140 ||
        sqe.hmc_target.value != 0 || sqe.bar_target.value != 0)
      `uvm_error("COMPOSE_OCC_METADATA",
                 "generationless OCC SQE metadata is wrong")
    if (qword0[63] != !slot.sq_wrap || qword0[61] != 1'b1 ||
        qword0[59] != 1'b1 || qword0[58:48] != 11'h345 ||
        qword0[45] != slot.sq_wrap ||
        qword0[44:40] != slot.sq_index[4:0] ||
        qword0[39:32] != RDMA_OP_OCC_FLUSH ||
        get_qword(sqe, 1) != 64'hff80_0000_0000_0000)
      `uvm_error("COMPOSE_OCC_FIELDS",
                 "generationless OCC SQE fields are wrong")
    for (int unsigned q = 2; q < 8; q++)
      if (get_qword(sqe, q) != 0)
        `uvm_error("COMPOSE_OCC_FIELDS",
                   "generationless OCC SQE has unexpected payload")
    if (expected.hardware_opcode != RDMA_OP_OCC_FLUSH ||
        expected.variant != "vf_flush")
      `uvm_error("COMPOSE_OCC_EXPECTED", "OCC expected response is wrong")
    if (command.function_h != function_h || command.opcode_key != key ||
        command.body != occ_body ||
        command.function_h.function_uid !=
          command_snapshot.function_h.function_uid ||
        command.function_h.object_id !=
          command_snapshot.function_h.object_id ||
        command.function_h.generation !=
          command_snapshot.function_h.generation ||
        command.opcode_key.profile_name !=
          command_snapshot.opcode_key.profile_name ||
        command.opcode_key.opcode != command_snapshot.opcode_key.opcode ||
        command.opcode_key.variant != command_snapshot.opcode_key.variant ||
        command.qpc_signature_source !=
          command_snapshot.qpc_signature_source ||
        command.vfid_override != command_snapshot.vfid_override ||
        command.use_vfid != command_snapshot.use_vfid ||
        command.timeout != command_snapshot.timeout ||
        occ_body.vf_flush != occ_snapshot.vf_flush ||
        occ_body.mr_serial_flush != occ_snapshot.mr_serial_flush ||
        occ_body.qpc != occ_snapshot.qpc ||
        occ_body.cqc != occ_snapshot.cqc ||
        occ_body.mrt != occ_snapshot.mrt ||
        occ_body.pble != occ_snapshot.pble ||
        occ_body.sqrqe != occ_snapshot.sqrqe ||
        occ_body.sgb_irqe != occ_snapshot.sgb_irqe ||
        occ_body.eirqe != occ_snapshot.eirqe ||
        occ_body.orqe != occ_snapshot.orqe ||
        occ_body.uaqe != occ_snapshot.uaqe ||
        occ_body.pd != occ_snapshot.pd ||
        occ_body.qpn != occ_snapshot.qpn ||
        occ_body.mr_serial != occ_snapshot.mr_serial ||
        occ_body.pd_backing.value != occ_snapshot.pd_backing.value)
      `uvm_error("COMPOSE_OCC_COMMAND_IMMUTABLE",
                 "OCC compose mutated the command")
    if (slot.function_h != function_h || slot.cmq_h != cmq_h ||
        slot.backing_addr.value != slot_snapshot.backing_addr.value ||
        slot.relative_offset != slot_snapshot.relative_offset ||
        slot.slot_sequence != slot_snapshot.slot_sequence ||
        slot.sq_index != slot_snapshot.sq_index ||
        slot.sq_wrap != slot_snapshot.sq_wrap)
      `uvm_error("COMPOSE_OCC_SLOT_IMMUTABLE",
                 "OCC compose mutated the slot")

    empty_body = rdma_hw_cmq_empty_body::type_id::create(
      "tq_flush_body");
    status = empty_body.validate();
    expect_status("COMPOSE_TQ_BODY_VALID", status, RDMA_SC_OK);
    if (empty_body.describe() != "rdma empty CMQ command body")
      `uvm_error("COMPOSE_TQ_BODY_DESCRIBE",
                 "typed empty body description is not meaningful")
    key = rdma_cmq_opcode_key::type_id::create("tq_flush_key");
    key.profile_name = "rdma";
    key.opcode = RDMA_OP_TQ_FLUSH;
    key.variant = "flush";
    command = rdma_cmq_command_desc::type_id::create("tq_flush_command");
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = empty_body;
    command.qpc_signature_source = null;
    command.vfid_override = 1'b1;
    command.use_vfid = 11'h345;
    command.timeout = 100;
    command_snapshot = rdma_cmq_command_desc::type_id::create(
      "tq_flush_command_snapshot");
    command_snapshot.copy(command);
    if (!$cast(empty_snapshot, command_snapshot.body)) begin
      `uvm_error("COMPOSE_TQ_SETUP", "empty snapshot body cast failed")
      return;
    end
    slot_snapshot = rdma_cmq_slot_context::type_id::create(
      "tq_flush_slot_snapshot");
    slot_snapshot.copy(slot);

    sqe = null;
    expected = null;
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_TQ_STATUS", status, RDMA_SC_OK);
    if (sqe == null || expected == null) begin
      `uvm_error("COMPOSE_TQ_OUTPUT", "TQ flush published null outputs")
      return;
    end
    qword0 = get_qword(sqe, 0);
    if (sqe.length != 64 || sqe.bytes.size() != 64 ||
        sqe.alignment != 64 || sqe.endian != RDMA_ENDIAN_BIG ||
        sqe.image_kind != RDMA_IMAGE_CMQ_SQE ||
        sqe.hardware_version != RDMA_HW_VERSION ||
        sqe.function_generation != TEST_GENERATION ||
        sqe.write_target_kind != RDMA_HW_TARGET_BACKING ||
        sqe.backing_target.value != 64'h0000_0000_4000_0140 ||
        sqe.hmc_target.value != 0 || sqe.bar_target.value != 0)
      `uvm_error("COMPOSE_TQ_METADATA", "TQ flush SQE metadata is wrong")
    if (qword0[63] != !slot.sq_wrap || qword0[59] != 1'b1 ||
        qword0[58:48] != 11'h345 || qword0[45] != slot.sq_wrap ||
        qword0[44:40] != slot.sq_index[4:0] ||
        qword0[39:32] != RDMA_OP_TQ_FLUSH)
      `uvm_error("COMPOSE_TQ_FIELDS", "TQ flush envelope is wrong")
    for (int unsigned q = 1; q < 8; q++)
      if (get_qword(sqe, q) != 0)
        `uvm_error("COMPOSE_TQ_FIELDS",
                   "TQ flush has nonempty body payload")
    if (expected.hardware_opcode != RDMA_OP_TQ_FLUSH ||
        expected.variant != "flush")
      `uvm_error("COMPOSE_TQ_EXPECTED", "TQ expected response is wrong")
    if (command.function_h != function_h || command.opcode_key != key ||
        command.body != empty_body ||
        empty_snapshot == empty_body ||
        command.function_h.function_uid !=
          command_snapshot.function_h.function_uid ||
        command.function_h.object_id !=
          command_snapshot.function_h.object_id ||
        command.function_h.generation !=
          command_snapshot.function_h.generation ||
        command.opcode_key.profile_name !=
          command_snapshot.opcode_key.profile_name ||
        command.opcode_key.opcode != command_snapshot.opcode_key.opcode ||
        command.opcode_key.variant != command_snapshot.opcode_key.variant ||
        command.qpc_signature_source !=
          command_snapshot.qpc_signature_source ||
        command.vfid_override != command_snapshot.vfid_override ||
        command.use_vfid != command_snapshot.use_vfid ||
        command.timeout != command_snapshot.timeout)
      `uvm_error("COMPOSE_TQ_COMMAND_IMMUTABLE",
                 "TQ compose mutated the command")
    if (slot.function_h != function_h || slot.cmq_h != cmq_h ||
        slot.backing_addr.value != slot_snapshot.backing_addr.value ||
        slot.relative_offset != slot_snapshot.relative_offset ||
        slot.slot_sequence != slot_snapshot.slot_sequence ||
        slot.sq_index != slot_snapshot.sq_index ||
        slot.sq_wrap != slot_snapshot.sq_wrap)
      `uvm_error("COMPOSE_TQ_SLOT_IMMUTABLE",
                 "TQ compose mutated the slot")
  endfunction

  // 功能：验证 owner-ready CQE 的 opcode/index/error/payload 解码和重复调用输出分离。
  // 输入/输出及副作用：无参数；构造本地 64B CQE，以 error codec 作状态 oracle，调用
  //   inspect_cqe 并比较 raw image 快照；不消费真实 CQ ring 或改写外部 cursor。
  // 失败/边界：owner 不匹配必须返回 OK/not-ready/null decoded；owner-ready 的未知
  //   opcode 必须返回 UNSUPPORTED_OPCODE，并保持 ready=0、decoded=null。
  function automatic void check_inspect_cqe();
    rdma_hw_cmq_hw_profile profile;
    rdma_hw_error_codec oracle;
    rdma_hw_image raw_cqe;
    rdma_hw_image snapshot;
    rdma_cmq_decoded_cqe decoded;
    rdma_cmq_decoded_cqe second_decoded;
    rdma_hw_cmq_completion payload;
    rdma_status expected_status;
    rdma_status status;
    bit ready;
    bit [7:0] ecode;

    ecode = RDMA_ECODE_EC_RCE_CQ_FULL;
    profile = rdma_hw_cmq_hw_profile::type_id::create(
      "inspect_profile");
    oracle = rdma_hw_error_codec::type_id::create("error_oracle");
    raw_cqe = make_cqe(1'b1, RDMA_OP_CQC_QUERY, ecode, 5'h1b, 1'b1);
    snapshot = clone_image(raw_cqe, "raw_cqe_snapshot");
    ready = 1'b0;
    decoded = null;
    status = profile.inspect_cqe(raw_cqe, 1'b1, ready, decoded);
    expect_status("INSPECT_STATUS", status, RDMA_SC_OK);
    if (!ready || decoded == null) begin
      `uvm_error("INSPECT_OUTPUT", "ready CQE did not publish decoded data")
      return;
    end
    expected_status = null;
    status = oracle.decode_status(ecode, RDMA_ENGINE_CMQ, expected_status);
    expect_status("INSPECT_ORACLE", status, RDMA_SC_OK);
    if (decoded.hardware_opcode != RDMA_OP_CQC_QUERY ||
        decoded.wqe_index != 5'h1b || !decoded.wqe_wrap ||
        decoded.hardware_ecode != ecode || decoded.command_status == null ||
        expected_status == null ||
        decoded.command_status.code != expected_status.code ||
        decoded.command_status.category != expected_status.category ||
        decoded.command_status.source_engine != expected_status.source_engine ||
        decoded.command_status.hardware_code != expected_status.hardware_code ||
        decoded.command_status.hardware_code_valid !=
          expected_status.hardware_code_valid)
      `uvm_error("INSPECT_FIELDS", "decoded CQE/error mapping is wrong")
    if (!$cast(payload, decoded.response_payload))
      `uvm_error("INSPECT_PAYLOAD_TYPE", "response payload lost xtr type")
    else if (!payload.owner || payload.opcode != RDMA_OP_CQC_QUERY ||
             payload.object_payload.size() != 56 ||
             payload.object_payload[0] != 8'h08 ||
             payload.object_payload[55] != 8'h3f)
      `uvm_error("INSPECT_PAYLOAD", "typed response payload is wrong")
    if (decoded.command_status.function_uid != 0 ||
        decoded.command_status.generation != 0 ||
        decoded.command_status.resource_id != 0 ||
        decoded.command_status.command_id != 0)
      `uvm_error("INSPECT_IDENTITY", "profile invented ticket identity")
    if (!images_equal(raw_cqe, snapshot))
      `uvm_error("INSPECT_IMMUTABLE", "inspect mutated raw CQE")

    second_decoded = null;
    status = profile.inspect_cqe(raw_cqe, 1'b1, ready, second_decoded);
    expect_status("INSPECT_DETACHED_STATUS", status, RDMA_SC_OK);
    if (!ready || second_decoded == null || second_decoded == decoded ||
        second_decoded.response_payload == decoded.response_payload)
      `uvm_error("INSPECT_DETACHED", "decoded CQE outputs alias")

    raw_cqe = make_cqe(1'b0, 8'hfe, 8'hff, 5'h1f, 1'b1);
    raw_cqe.bytes[63] = 8'hff;
    decoded = rdma_cmq_decoded_cqe::type_id::create("stale_decoded");
    ready = 1'b1;
    status = profile.inspect_cqe(raw_cqe, 1'b1, ready, decoded);
    expect_status("INSPECT_OWNER_MISMATCH_STATUS", status, RDMA_SC_OK);
    if (ready || decoded != null)
      `uvm_error("INSPECT_OWNER_MISMATCH", "stale CQE was inspected")

    raw_cqe = make_cqe(1'b1, 8'hfe, 8'hff, 5'h1f, 1'b1);
    decoded = rdma_cmq_decoded_cqe::type_id::create(
      "stale_malformed_decoded");
    ready = 1'b1;
    status = profile.inspect_cqe(raw_cqe, 1'b1, ready, decoded);
    expect_status("INSPECT_MALFORMED_STATUS", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);
    if (ready || decoded != null)
      `uvm_error("INSPECT_MALFORMED",
                 "malformed CQE published partial outputs")
  endfunction

  // 功能：验证 CMQ SQ doorbell 的 PI/polarity bit、BAR metadata 和重复编码的输出分离。
  // 输入/输出及副作用：无参数；用本地 CMQ handle 调用真实 registry/profile 编码，
  //   变异首次 image 后再次编码；不执行 MMIO，所有 image 均由测试持有。
  // 失败/边界：null handle、非 CMQ kind 或 final_pi=32 必须返回 INVALID_ARGUMENT，
  //   且覆盖调用方预置 image 为 null；有效编码不得复用先前 image 节点。
  function automatic void check_encode_doorbell();
    rdma_hw_cmq_hw_profile profile;
    rdma_handle cmq_h;
    rdma_hw_image image;
    rdma_hw_image second_image;
    rdma_status status;
    bit [63:0] word;

    profile = rdma_hw_cmq_hw_profile::type_id::create(
      "doorbell_profile");
    cmq_h = make_handle("doorbell_cmq", RDMA_RESOURCE_CMQ, 32'h55);
    image = null;
    status = profile.encode_doorbell(cmq_h, 17, 1'b1, image);
    expect_status("DOORBELL_STATUS", status, RDMA_SC_OK);
    if (image == null) begin
      `uvm_error("DOORBELL_OUTPUT", "successful doorbell encode is null")
      return;
    end
    word = get_qword(image, 0);
    if (image.length != 8 || image.bytes.size() != 8 ||
        image.alignment != 8 || image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != RDMA_IMAGE_DOORBELL ||
        image.hardware_version != RDMA_HW_VERSION ||
        image.function_generation != TEST_GENERATION ||
        image.write_target_kind != RDMA_HW_TARGET_BAR ||
        image.bar_target.value != 64'h000 ||
        image.backing_target.value != 0 || image.hmc_target.value != 0 ||
        word[36:32] != 5'd17 || word[37] != 1'b1)
      `uvm_error("DOORBELL_FIELDS", "CMQ SQ doorbell is wrong")

    image.bytes[0] ^= 8'hff;
    second_image = null;
    status = profile.encode_doorbell(cmq_h, 17, 1'b1, second_image);
    expect_status("DOORBELL_DETACHED_STATUS", status, RDMA_SC_OK);
    if (second_image == null || second_image == image ||
        get_qword(second_image, 0)[37:32] != 6'b1_10001)
      `uvm_error("DOORBELL_DETACHED", "doorbell output aliases codec state")

    image = rdma_hw_image::type_id::create("stale_bad_doorbell");
    status = profile.encode_doorbell(null, 17, 1'b1, image);
    expect_status("DOORBELL_NULL_HANDLE", status, RDMA_SC_INVALID_ARGUMENT);
    if (image != null)
      `uvm_error("DOORBELL_NULL_HANDLE", "failure published image")
    cmq_h.kind = RDMA_RESOURCE_CQ;
    image = rdma_hw_image::type_id::create("stale_wrong_handle_doorbell");
    status = profile.encode_doorbell(cmq_h, 17, 1'b1, image);
    expect_status("DOORBELL_WRONG_HANDLE", status, RDMA_SC_INVALID_ARGUMENT);
    if (image != null)
      `uvm_error("DOORBELL_WRONG_HANDLE", "failure published image")
    cmq_h.kind = RDMA_RESOURCE_CMQ;
    image = rdma_hw_image::type_id::create("stale_pi_range_doorbell");
    status = profile.encode_doorbell(cmq_h, 32, 1'b1, image);
    expect_status("DOORBELL_PI_RANGE", status, RDMA_SC_INVALID_ARGUMENT);
    if (image != null)
      `uvm_error("DOORBELL_PI_RANGE", "failure published image")
  endfunction

  // 功能：check_qpc_driver_fixed_vfid 验证 QPC_CREATE 的 VFID 字段由驱动固定为零。
  // 输入/输出及副作用：无参数；构造本地 Function、QPC body、slot 并调用
  //   production compose_sqe；只发布 UVM 断言，不触碰外部 I/O 或转移句柄所有权。
  // 失败/边界：vfid_override 或 use_vfid 任一非零位未返回 INVALID_ARGUMENT，
  //   或拒绝路径发布 image/expected 时报告错误；循环覆盖 11-bit use_vfid 边界。
  function automatic void check_qpc_driver_fixed_vfid();
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_hw_qpc_command_body body;
    rdma_cmq_command_desc command;
    rdma_cmq_opcode_key key;
    rdma_cmq_slot_context slot;
    rdma_hw_image image;
    rdma_cmq_expected_response expected;
    rdma_status status;
    rdma_hw_cmq_hw_profile profile;

    profile = rdma_hw_cmq_hw_profile::type_id::create("qpc_fixed_profile");
    function_h = make_function("qpc_fixed_function");
    cmq_h = make_handle("qpc_fixed_cmq", RDMA_RESOURCE_CMQ, 32'h44);
    body = rdma_hw_qpc_command_body::type_id::create("qpc_fixed_body");
    body.qp_h = make_handle("qpc_fixed_qp", RDMA_RESOURCE_QP, 24'ha1b2c3);
    key = rdma_cmq_opcode_key::type_id::create("qpc_fixed_key");
    key.profile_name = "rdma";
    key.opcode = RDMA_OP_QPC_CREATE;
    key.variant = "rc";
    command = rdma_cmq_command_desc::type_id::create("qpc_fixed_command");
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = body;
    command.timeout = 100;
    slot = make_slot("qpc_fixed_slot", function_h, cmq_h);

    command.vfid_override = 1'b1;
    status = profile.compose_sqe(command, slot, image, expected);
    expect_status("QPC_FIXED_OVERRIDE", status, RDMA_SC_INVALID_ARGUMENT);
    if (image != null || expected != null)
      `uvm_error("QPC_FIXED_OVERRIDE_OUTPUT", "fixed VFID rejection published output")

    command.vfid_override = 1'b0;
    for (int unsigned bit_index = 0; bit_index < 11; bit_index++) begin
      command.use_vfid = '0;
      command.use_vfid[bit_index] = 1'b1;
      command.vfid_override = 1'b1;
      image = null;
      expected = null;
      status = profile.compose_sqe(command, slot, image, expected);
      expect_status("QPC_FIXED_USE_VFID", status, RDMA_SC_INVALID_ARGUMENT);
      if (image != null || expected != null)
        `uvm_error("QPC_FIXED_USE_VFID_OUTPUT", "fixed VFID rejection published output")
    end
  endfunction

  // 功能：按依赖顺序运行 profile 组合、body 快照/canonicalization、SQE/CQE 和 doorbell
  //   契约场景，使所有 factory/callback 故障窗口在同一 UVM test 内受控。
  // 输入/输出及副作用：phase 由 UVM 输入；task 在首尾配对 objection，依次调用十二组
  //   本地断言 helper；结果通过 UVM report 可见，不执行 VCS 外的资源清理。
  // 失败/边界：helper 的普通拒绝只报告错误并继续后续场景；若 UVM fatal 终止仿真，
  //   phase 无恢复语义，否则全部 helper 返回后必定 drop objection。
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_profile_validation();
    check_driver_034_registry_contract();
    check_compose_sqe();
    check_compose_generation_policy();
    check_inspect_cqe();
    check_encode_doorbell();
    check_qpc_driver_fixed_vfid();
    phase.drop_objection(this);
  endtask
endclass
