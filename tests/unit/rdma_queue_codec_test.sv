// 目录：测试层 unit/rdma_queue_codec_test.sv。
// 职责：验证 rdma_queue_codec_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_queue_codec_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_queue_codec_test extends uvm_test;
  `uvm_component_utils(rdma_queue_codec_test)

  // 功能：构造 rdma_queue_codec_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_codec_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_queue_codec_test", uvm_component parent=null);
    super.new(name,parent);
  endfunction

  // 功能：在 rdma_queue_codec_test 中，h 从测试 fixture 返回预先构造的 Function/队列句柄或 DMA 上下文，保持调用方与 fixture 使用同一实例。
  // 输入/输出及副作用：n（输入）、k（输入）、id（输入）；h 读取 n、k、id 并使用字段 x、x.kind、x.object_id、x.function_uid、x.generation；函数返回 rdma_handle，不取得调用方资源所有权。
  // 失败/边界：h 的结果直接由 return x 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_handle h(string n, rdma_resource_kind_e k, int unsigned id);
    rdma_handle x=rdma_handle::type_id::create(n); x.kind=k; x.object_id=id;
    x.function_uid=64'h1122; x.generation=1; return x;
  endfunction

  // 功能：ok 按函数体读取当前字段并生成 void 结果，供调用方进行诊断或分支决策；不修改外部资源。
  // 输入/输出及副作用：l（输入）、s（输入）；ok 读取 l、s 并使用输入参数和固定枚举/常量；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  function automatic void ok(string l, rdma_status s);
    if (s==null || !s.ok()) `uvm_error(l, s==null?"null":s.convert2string());
  endfunction

  // 功能：在 rdma_queue_codec_test 中，eq_bytes 逐字节比较两个硬件镜像并在长度或内容不一致时报告测试错误。
  // 输入/输出及副作用：l（输入）、a（输入）、b（输入）；eq_bytes 读取 l、a、b 并使用字段 i；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：eq_bytes 无返回值，仅执行 函数体中的顺序操作；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function automatic void eq_bytes(string l, rdma_hw_image a, rdma_hw_image b);
    if (a==null || b==null || a.bytes.size()!=b.bytes.size()) begin `uvm_error(l,"image mismatch"); return; end
    foreach (a.bytes[i]) if (a.bytes[i]!==b.bytes[i]) `uvm_error(l,$sformatf("byte %0d",i));
  endfunction

  // 功能：make_event_image 将已序列化的 16-byte CEQE/AEQE payload 包装成带完整
  //   metadata 的 detached hardware image，供 raw decode 与负向测试复用。
  // 输入/输出及副作用：name、kind、payload（输入）；返回新建 image，复制 payload
  //   字节并设置长度、端序、版本、generation 和无写目标 metadata，不取得 payload 所有权。
  // 失败/边界：payload 长度不是对应 event entry 大小时仍构造 image，由 codec 的
  //   validate_image 负责拒绝；空 payload 不隐式填零，调用方须显式准备 raw bytes。
  function automatic rdma_hw_image make_event_image(
      string name,
      rdma_image_kind_e kind,
      byte unsigned payload[]
  );
    rdma_hw_image image;

    image = rdma_hw_image::type_id::create(name);
    foreach (payload[i])
      image.bytes.push_back(payload[i]);
    image.length = payload.size();
    image.alignment = payload.size();
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = kind;
    image.hardware_version = RDMA_HW_VERSION;
    image.function_generation = 1;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;
    return image;
  endfunction

  // 功能：在 rdma_queue_codec_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    rdma_codec_registry r; rdma_status s; rdma_codec_base c; rdma_hw_image im,im2; rdma_hw_model m;
    rdma_hw_sqe_model sq, sq2; rdma_hw_rqe_model rq, rq2; rdma_hw_cqe_model cq, cq2;
    rdma_hw_ceqe_model ceqe;
    rdma_hw_ceqe_model ceqe_urc;
    rdma_hw_ceqe_model ceqe_copy;
    rdma_hw_ceqe_model ceqe_decoded;
    rdma_hw_aeqe_model aeqe;
    rdma_hw_aeqe_model aeqe_copy;
    rdma_hw_aeqe_model aeqe_decoded;
    rdma_sqe_rc_ext re; rdma_sge sg; byte unsigned bad[];
    rdma_hw_cqe_codec profile_codec;
    rdma_hw_image profile_image;
    rdma_hw_qword_builder profile_builder;
    rdma_hw_qword_builder rqe_builder;
    bit [63:0] profile_words[];
    bit [63:0] rqe_words[];
    byte unsigned rqe_bytes[];
    rdma_hw_qword_builder eq_builder;
    bit [63:0] eq_words[];
    byte unsigned event_bytes[];
    rdma_hw_image eq_image;
    rdma_hw_image eq_image_copy;
    rdma_hw_model eq_model;
    rdma_hw_aeqe_model decoded_aeqe;
    bit [54:0] initial_sgb_pa;
    bit [54:0] previous_sgb_pa;
    phase.raise_objection(this);
    r=rdma_codec_registry::type_id::create("r"); s=rdma_register_queue_codecs(r); ok("register",s);
    // 设计说明：CQ handle.object_id 是 resource manager 分配的 global incarnation，
    // cqn 是 Function-local CQ ID；二者不共享命名空间，model/codec 只能校验 handle
    // kind 和各字段宽度，完整 identity 由 queue-data attachment 边界完成。
    ceqe=rdma_hw_ceqe_model::type_id::create("ceqe_local_cqn");
    ceqe.cq_h=h("ceqe_cq",RDMA_RESOURCE_CQ,32'h3000_0002);
    ceqe.cqn=21'h1; ceqe.qpn=0; ceqe.cq_pi=16'h1; ceqe.cq_pi_wrap=0;
    ceqe.valid=0; ceqe.ecode=0; ceqe.packet_opcode=0;
    s=ceqe.validate(); ok("ceqe global handle local cqn validate",s);
    s=r.lookup('{hw_version:"rdma",image_kind:RDMA_IMAGE_CEQE,object_type:"ceqe",variant:"default",opcode:0},c);
    ok("lookup ceqe",s); s=c.encode(ceqe,im); ok("ceqe global handle local cqn encode",s);

    // RED: defs.h CEQE URC/abnormal layout uses fields that the legacy codec
    // currently classifies as reserved.  The raw image below mirrors every
    // driver-owned CEQE bit and must decode successfully after the fix.
    eq_builder = new("ceqe_urc_red_builder");
    s = eq_builder.reset(RDMA_CEQE_BYTES);
    ok("ceqe urc red reset", s);
    s = eq_builder.put_field(0, 63, 1, 1);
    s = eq_builder.put_field(0, 62, 1, 1);
    s = eq_builder.put_field(0, 40, 21, 21'h15555);
    s = eq_builder.put_field(0, 39, 1, 1);
    s = eq_builder.put_field(0, 38, 1, 1);
    s = eq_builder.put_field(0, 16, 21, 21'h1AAAAA);
    s = eq_builder.put_field(0, 8, 8, 8'hF4);
    s = eq_builder.put_field(0, 0, 8, 8'h9A);
    s = eq_builder.put_field(8, 56, 2, 2'b10);
    s = eq_builder.put_field(8, 48, 8, 8'hA5);
    s = eq_builder.put_field(8, 47, 1, 1);
    s = eq_builder.put_field(8, 32, 15, 15'h4567);
    s = eq_builder.put_field(8, 31, 1, 1);
    s = eq_builder.put_field(8, 16, 15, 15'h2345);
    s = eq_builder.put_field(8, 15, 1, 1);
    s = eq_builder.put_field(8, 0, 15, 15'h3456);
    ok("ceqe urc red fields", s);
    s = eq_builder.serialize(event_bytes);
    ok("ceqe urc red serialize", s);
    eq_image = rdma_hw_image::type_id::create("ceqe_urc_red_image");
    foreach (event_bytes[i]) eq_image.bytes.push_back(event_bytes[i]);
    eq_image.length = RDMA_CEQE_BYTES;
    eq_image.alignment = RDMA_CEQE_BYTES;
    eq_image.endian = RDMA_ENDIAN_BIG;
    eq_image.image_kind = RDMA_IMAGE_CEQE;
    eq_image.hardware_version = RDMA_HW_VERSION;
    eq_image.function_generation = 1;
    eq_image.write_target_kind = RDMA_HW_TARGET_NONE;
    eq_image.backing_target = '0;
    eq_image.hmc_target = '0;
    eq_image.bar_target = '0;
    s = c.decode(eq_image, eq_model);
    if (s == null || !s.ok() || !$cast(ceqe_decoded, eq_model) ||
        ceqe_decoded.valid !== 1'b1 ||
        ceqe_decoded.urc_flag !== 1'b1 ||
        ceqe_decoded.qpn !== 21'h15555 ||
        ceqe_decoded.cqn !== 21'h1aaaaa ||
        ceqe_decoded.ecode !== 8'hf4 ||
        ceqe_decoded.packet_opcode !== 8'h9a ||
        ceqe_decoded.urc_sq_cqe_valid !== 1'b1 ||
        ceqe_decoded.urc_rq_cqe_valid !== 1'b1 ||
        ceqe_decoded.urc_abnormal_cqe_type !== 2'b10 ||
        ceqe_decoded.urc_abnormal_cqe_remote_ecode !== 8'ha5 ||
        ceqe_decoded.urc_abnormal_cqe_wqe_idx_wrap !== 1'b1 ||
        ceqe_decoded.urc_abnormal_cqe_wqe_idx !== 15'h4567 ||
        ceqe_decoded.urc_hw_cpl_sq_wqe_idx_wrap !== 1'b1 ||
        ceqe_decoded.urc_hw_cpl_sq_wqe_idx !== 15'h2345 ||
        ceqe_decoded.urc_hw_cpl_rq_wqe_idx_wrap !== 1'b1 ||
        ceqe_decoded.urc_hw_cpl_rq_wqe_idx !== 15'h3456)
      `uvm_error("CEQE_URC_RED",
                 $sformatf("driver-owned CEQE URC fields were rejected: %s",
                           s == null ? "<null>" : s.message))
    else begin
      s = c.encode(ceqe_decoded, eq_image_copy);
      ok("ceqe urc raw decode re-encode", s);
      eq_bytes("ceqe urc raw decode byte equivalence", eq_image,
               eq_image_copy);
    end

    s = r.lookup(
        '{hw_version:"rdma", image_kind:RDMA_IMAGE_AEQE,
          object_type:"aeqe", variant:"default", opcode:0},
        c);
    ok("lookup aeqe", s);

    // RED: defs.h AEQE includes flags, split CQN/EQN coordinates and URC
    // queue fields.  All are intentionally nonzero so an incomplete mask
    // cannot pass this test by accident.
    eq_builder = new("aeqe_abnormal_red_builder");
    s = eq_builder.reset(RDMA_AEQE_BYTES);
    ok("aeqe abnormal red reset", s);
    s = eq_builder.put_field(0, 63, 1, 1);
    s = eq_builder.put_field(0, 60, 3, 3'd5);
    s = eq_builder.put_field(0, 59, 1, 1);
    s = eq_builder.put_field(0, 58, 1, 1);
    s = eq_builder.put_field(0, 57, 1, 1);
    s = eq_builder.put_field(0, 56, 1, 1);
    s = eq_builder.put_field(0, 54, 2, 2'b10);
    s = eq_builder.put_field(0, 40, 13, 13'h1555);
    s = eq_builder.put_field(0, 32, 8, 8'h81);
    s = eq_builder.put_field(0, 24, 8, 8'hFF);
    s = eq_builder.put_field(0, 18, 6, 6'h2A);
    s = eq_builder.put_field(0, 0, 18, 18'h2AAAA);
    s = eq_builder.put_field(8, 56, 8, 8'hE1);
    s = eq_builder.put_field(8, 55, 1, 1);
    s = eq_builder.put_field(8, 32, 23, 23'h654321);
    s = eq_builder.put_field(8, 16, 12, 12'hABC);
    s = eq_builder.put_field(8, 0, 16, 16'h1234);
    ok("aeqe abnormal red fields", s);
    s = eq_builder.serialize(event_bytes);
    ok("aeqe abnormal red serialize", s);
    eq_image = rdma_hw_image::type_id::create("aeqe_abnormal_red_image");
    foreach (event_bytes[i]) eq_image.bytes.push_back(event_bytes[i]);
    eq_image.length = RDMA_AEQE_BYTES;
    eq_image.alignment = RDMA_AEQE_BYTES;
    eq_image.endian = RDMA_ENDIAN_BIG;
    eq_image.image_kind = RDMA_IMAGE_AEQE;
    eq_image.hardware_version = RDMA_HW_VERSION;
    eq_image.function_generation = 1;
    eq_image.write_target_kind = RDMA_HW_TARGET_NONE;
    eq_image.backing_target = '0;
    eq_image.hmc_target = '0;
    eq_image.bar_target = '0;
    s = c.decode(eq_image, eq_model);
    if (s == null || !s.ok() || !$cast(decoded_aeqe, eq_model) ||
        decoded_aeqe.valid !== 1'b1 ||
        decoded_aeqe.qp_state !== 3'd5 ||
        decoded_aeqe.srfq_en !== 1'b1 ||
        decoded_aeqe.overflow_flag !== 1'b1 ||
        decoded_aeqe.urc_flag !== 1'b1 ||
        decoded_aeqe.cq_invalid_flag !== 1'b1 ||
        decoded_aeqe.urc_abnormal_cqe_type !== 2'b10 ||
        decoded_aeqe.cqn_eqn_high !== 13'h1555 ||
        decoded_aeqe.cqn_eqn_low !== 6'h2a ||
        decoded_aeqe.packet_opcode !== 8'h81 ||
        decoded_aeqe.ecode !== 8'hff ||
        decoded_aeqe.qpn !== 18'h2aaaa ||
        decoded_aeqe.urc_remote_ecode !== 8'he1 ||
        decoded_aeqe.wqe_wrap !== 1'b1 ||
        decoded_aeqe.wqe_index !== 23'h654321 ||
        decoded_aeqe.srfqn !== 12'habc ||
        decoded_aeqe.srfqe_idx !== 16'h1234 ||
        decoded_aeqe.logical_cqn_eqn() !== 19'h5556a)
      `uvm_error("AEQE_ABNORMAL_RED", "driver-owned AEQE fields were rejected")
    else begin
      s = c.encode(decoded_aeqe, eq_image_copy);
      ok("aeqe raw decode re-encode", s);
      eq_bytes("aeqe raw decode byte equivalence", eq_image,
               eq_image_copy);
    end

    // CEQE RC variant：RC qword1 只发布 CQ consumer index，完整往返必须保留
    //   valid/common 字段及 wrap；URC 专用字段保持零，避免两个布局相互污染。
    s = r.lookup(
        '{hw_version:"rdma", image_kind:RDMA_IMAGE_CEQE,
          object_type:"ceqe", variant:"default", opcode:0},
        c);
    ok("lookup ceqe for rc roundtrip", s);
    ceqe = rdma_hw_ceqe_model::type_id::create("ceqe_rc_roundtrip");
    ceqe.cq_h = h("ceqe_rc_cq", RDMA_RESOURCE_CQ, 32'h3000_0010);
    ceqe.qpn = 21'h15555;
    ceqe.cqn = 21'h1aaaaa;
    ceqe.ecode = 8'hf4;
    ceqe.packet_opcode = 8'h9a;
    ceqe.cq_pi = 16'hbeef;
    ceqe.cq_pi_wrap = 1'b1;
    ceqe.valid = 1'b1;
    s = c.encode(ceqe, im);
    ok("ceqe rc encode", s);
    s = c.decode(im, eq_model);
    ok("ceqe rc decode", s);
    if (s == null || !s.ok() || !$cast(ceqe_decoded, eq_model) ||
        ceqe_decoded.urc_flag !== 1'b0 ||
        ceqe_decoded.qpn !== ceqe.qpn ||
        ceqe_decoded.cqn !== ceqe.cqn ||
        ceqe_decoded.ecode !== ceqe.ecode ||
        ceqe_decoded.packet_opcode !== ceqe.packet_opcode ||
        ceqe_decoded.cq_pi !== ceqe.cq_pi ||
        ceqe_decoded.cq_pi_wrap !== ceqe.cq_pi_wrap ||
        ceqe_decoded.valid !== ceqe.valid)
      `uvm_error("CEQE_RC_ROUNDTRIP", "CEQE RC fields did not round-trip")

    ceqe_copy = rdma_hw_ceqe_model::type_id::create("ceqe_rc_copy");
    ceqe_copy.copy(ceqe);
    if (ceqe_copy.qpn !== ceqe.qpn || ceqe_copy.cqn !== ceqe.cqn ||
        ceqe_copy.cq_pi !== ceqe.cq_pi ||
        ceqe_copy.cq_pi_wrap !== ceqe.cq_pi_wrap ||
        ceqe_copy.urc_flag !== ceqe.urc_flag)
      `uvm_error("CEQE_RC_COPY", "CEQE RC detached copy lost fields")

    // CEQE URC variant：qword1 的八组驱动字段必须编码到原始坐标，不能被
    //   RC consumer-index 解释；随后验证 detached copy 仍包含所有 URC 字段。
    ceqe_urc = rdma_hw_ceqe_model::type_id::create("ceqe_urc_roundtrip");
    ceqe_urc.cq_h = h("ceqe_urc_cq", RDMA_RESOURCE_CQ, 32'h3000_0011);
    ceqe_urc.qpn = 21'h15555;
    ceqe_urc.cqn = 21'h1aaaaa;
    ceqe_urc.ecode = 8'hf4;
    ceqe_urc.packet_opcode = 8'h9a;
    ceqe_urc.valid = 1'b1;
    ceqe_urc.urc_flag = 1'b1;
    ceqe_urc.urc_sq_cqe_valid = 1'b1;
    ceqe_urc.urc_rq_cqe_valid = 1'b1;
    ceqe_urc.urc_abnormal_cqe_type = 2'b10;
    ceqe_urc.urc_abnormal_cqe_remote_ecode = 8'ha5;
    ceqe_urc.urc_abnormal_cqe_wqe_idx_wrap = 1'b1;
    ceqe_urc.urc_abnormal_cqe_wqe_idx = 15'h4567;
    ceqe_urc.urc_hw_cpl_sq_wqe_idx_wrap = 1'b1;
    ceqe_urc.urc_hw_cpl_sq_wqe_idx = 15'h2345;
    ceqe_urc.urc_hw_cpl_rq_wqe_idx_wrap = 1'b1;
    ceqe_urc.urc_hw_cpl_rq_wqe_idx = 15'h3456;
    s = c.encode(ceqe_urc, im);
    ok("ceqe urc encode", s);
    s = c.decode(im, eq_model);
    ok("ceqe urc decode", s);
    if (s == null || !s.ok() || !$cast(ceqe_decoded, eq_model) ||
        ceqe_decoded.urc_flag !== 1'b1 ||
        ceqe_decoded.urc_sq_cqe_valid !== ceqe_urc.urc_sq_cqe_valid ||
        ceqe_decoded.urc_rq_cqe_valid !== ceqe_urc.urc_rq_cqe_valid ||
        ceqe_decoded.urc_abnormal_cqe_type !== ceqe_urc.urc_abnormal_cqe_type ||
        ceqe_decoded.urc_abnormal_cqe_remote_ecode !==
            ceqe_urc.urc_abnormal_cqe_remote_ecode ||
        ceqe_decoded.urc_abnormal_cqe_wqe_idx_wrap !==
            ceqe_urc.urc_abnormal_cqe_wqe_idx_wrap ||
        ceqe_decoded.urc_abnormal_cqe_wqe_idx !==
            ceqe_urc.urc_abnormal_cqe_wqe_idx ||
        ceqe_decoded.urc_hw_cpl_sq_wqe_idx_wrap !==
            ceqe_urc.urc_hw_cpl_sq_wqe_idx_wrap ||
        ceqe_decoded.urc_hw_cpl_sq_wqe_idx !== ceqe_urc.urc_hw_cpl_sq_wqe_idx ||
        ceqe_decoded.urc_hw_cpl_rq_wqe_idx_wrap !==
            ceqe_urc.urc_hw_cpl_rq_wqe_idx_wrap ||
        ceqe_decoded.urc_hw_cpl_rq_wqe_idx !== ceqe_urc.urc_hw_cpl_rq_wqe_idx)
      `uvm_error("CEQE_URC_ROUNDTRIP", "CEQE URC fields did not round-trip")

    ceqe_copy = rdma_hw_ceqe_model::type_id::create("ceqe_urc_copy");
    ceqe_copy.copy(ceqe_urc);
    if (ceqe_copy.urc_flag !== ceqe_urc.urc_flag ||
        ceqe_copy.urc_abnormal_cqe_type !== ceqe_urc.urc_abnormal_cqe_type ||
        ceqe_copy.urc_abnormal_cqe_remote_ecode !==
            ceqe_urc.urc_abnormal_cqe_remote_ecode ||
        ceqe_copy.urc_hw_cpl_sq_wqe_idx !== ceqe_urc.urc_hw_cpl_sq_wqe_idx ||
        ceqe_copy.urc_hw_cpl_rq_wqe_idx !== ceqe_urc.urc_hw_cpl_rq_wqe_idx)
      `uvm_error("CEQE_URC_COPY", "CEQE URC detached copy lost fields")

    // 变体互斥负向：RC image 不得偷偷携带 URC completion 字段，URC image
    //   也不得复用 RC 的 CQ_PI/CQ_PI_WRAP；两条路径都必须在发布 image 前拒绝。
    ceqe.urc_sq_cqe_valid = 1'b1;
    s = c.encode(ceqe, im);
    if (s == null || s.ok())
      `uvm_error("CEQE_RC_VARIANT", "RC CEQE accepted URC-only field")
    ceqe.urc_sq_cqe_valid = 1'b0;
    ceqe_urc.cq_pi = 16'h1;
    s = c.encode(ceqe_urc, im);
    if (s == null || s.ok())
      `uvm_error("CEQE_URC_VARIANT", "URC CEQE accepted RC CI field")

    // AEQE model round-trip：这里同时覆盖 defs.h 的 flags、拆分 CQN/EQN、
    //   URC queue 坐标和 SRFQ 坐标，logical_cqn_eqn 必须按驱动左移 6 位重组。
    s = r.lookup(
        '{hw_version:"rdma", image_kind:RDMA_IMAGE_AEQE,
          object_type:"aeqe", variant:"default", opcode:0},
        c);
    ok("lookup aeqe for roundtrip", s);
    aeqe = rdma_hw_aeqe_model::type_id::create("aeqe_roundtrip");
    aeqe.target_h = h("aeqe_qp", RDMA_RESOURCE_QP, 32'h4000_0001);
    aeqe.valid = 1'b1;
    aeqe.qp_state = 3'd5;
    aeqe.srfq_en = 1'b1;
    aeqe.overflow_flag = 1'b1;
    aeqe.urc_flag = 1'b1;
    aeqe.cq_invalid_flag = 1'b1;
    aeqe.urc_abnormal_cqe_type = 2'b10;
    aeqe.cqn_eqn_high = 13'h1555;
    aeqe.cqn_eqn_low = 6'h2a;
    aeqe.packet_opcode = 8'h81;
    aeqe.ecode = 8'hff;
    aeqe.qpn = 18'h2aaaa;
    aeqe.urc_remote_ecode = 8'he1;
    aeqe.wqe_wrap = 1'b1;
    aeqe.wqe_index = 23'h654321;
    aeqe.srfqn = 12'habc;
    aeqe.srfqe_idx = 16'h1234;
    s = c.encode(aeqe, im);
    ok("aeqe encode", s);
    s = c.decode(im, eq_model);
    ok("aeqe decode", s);
    if (s == null || !s.ok() || !$cast(aeqe_decoded, eq_model) ||
        aeqe_decoded.valid !== aeqe.valid ||
        aeqe_decoded.qp_state !== aeqe.qp_state ||
        aeqe_decoded.srfq_en !== aeqe.srfq_en ||
        aeqe_decoded.overflow_flag !== aeqe.overflow_flag ||
        aeqe_decoded.urc_flag !== aeqe.urc_flag ||
        aeqe_decoded.cq_invalid_flag !== aeqe.cq_invalid_flag ||
        aeqe_decoded.urc_abnormal_cqe_type !== aeqe.urc_abnormal_cqe_type ||
        aeqe_decoded.cqn_eqn_high !== aeqe.cqn_eqn_high ||
        aeqe_decoded.cqn_eqn_low !== aeqe.cqn_eqn_low ||
        aeqe_decoded.packet_opcode !== aeqe.packet_opcode ||
        aeqe_decoded.ecode !== aeqe.ecode ||
        aeqe_decoded.qpn !== aeqe.qpn ||
        aeqe_decoded.urc_remote_ecode !== aeqe.urc_remote_ecode ||
        aeqe_decoded.wqe_wrap !== aeqe.wqe_wrap ||
        aeqe_decoded.wqe_index !== aeqe.wqe_index ||
        aeqe_decoded.srfqn !== aeqe.srfqn ||
        aeqe_decoded.srfqe_idx !== aeqe.srfqe_idx ||
        aeqe_decoded.logical_cqn_eqn() !== aeqe.logical_cqn_eqn())
      `uvm_error("AEQE_ROUNDTRIP", "AEQE fields did not round-trip")

    aeqe_copy = rdma_hw_aeqe_model::type_id::create("aeqe_copy");
    aeqe_copy.copy(aeqe);
    if (aeqe_copy.srfq_en !== aeqe.srfq_en ||
        aeqe_copy.urc_flag !== aeqe.urc_flag ||
        aeqe_copy.urc_remote_ecode !== aeqe.urc_remote_ecode ||
        aeqe_copy.wqe_index !== aeqe.wqe_index ||
        aeqe_copy.srfqn !== aeqe.srfqn ||
        aeqe_copy.srfqe_idx !== aeqe.srfqe_idx ||
        aeqe_copy.logical_cqn_eqn() !== aeqe.logical_cqn_eqn())
      `uvm_error("AEQE_COPY", "AEQE detached copy lost fields")

    // logical_cqn_eqn 的上界覆盖 13-bit high 与 6-bit low 的拼接边界，
    //   防止实现把 low 当成 high 的低位截断或错误左移。
    aeqe.cqn_eqn_high = 13'h1fff;
    aeqe.cqn_eqn_low = 6'h3f;
    if (aeqe.logical_cqn_eqn() !== 19'h7ffff)
      `uvm_error("AEQE_CQN_EQN_BOUNDARY", "AEQE CQN/EQN upper boundary is wrong")

    // 变体负向：SRFQ 坐标必须由 SRFQ_EN 拥有；URC abnormal/remote 字段必须
    //   由 URC_FLAG 拥有。queue WQE wrap/index 则按 event.c 无条件解码，允许
    //   urc_flag=0 的非零组合，避免模型比真实驱动更严格。
    aeqe.srfq_en = 1'b0;
    s = c.encode(aeqe, im);
    if (s == null || s.ok())
      `uvm_error("AEQE_SRFQ_VARIANT", "AEQE accepted SRFQ fields without enable")
    aeqe.srfq_en = 1'b1;
    aeqe.urc_flag = 1'b0;
    s = c.encode(aeqe, im);
    if (s == null || s.ok())
      `uvm_error("AEQE_URC_VARIANT", "AEQE accepted URC fields without flag")
    aeqe.urc_flag = 1'b1;

    // 驱动 qp.h 的 xtrdma_qp_st 只有 0..5；3-bit wire 的 6/7 是未知值，
    //   编码和 raw decode 都必须 fail-closed，不能仅因字段宽度足够而放行。
    aeqe.qp_state = 3'd6;
    s = c.encode(aeqe, im);
    if (s == null || s.ok())
      `uvm_error("AEQE_QP_STATE", "AEQE accepted an unknown driver QP state")
    aeqe.qp_state = 3'd5;

    // 保留位负向：AEQE qword0 bit53 与 qword1 bits31:28 均不在 defs.h
    //   字段集合中，raw decode 必须 fail-closed 且不能发布半成品 model。
    s = c.encode(aeqe, im);
    ok("aeqe re-encode for reserved red", s);
    eq_builder = new("aeqe_reserved_builder");
    s = eq_builder.deserialize(im.bytes);
    ok("aeqe reserved deserialize", s);
    s = eq_builder.put_field(0, 53, 1, 1);
    ok("aeqe qword0 reserved field", s);
    s = eq_builder.serialize(event_bytes);
    ok("aeqe qword0 reserved serialize", s);
    eq_image = make_event_image("aeqe_qword0_reserved", RDMA_IMAGE_AEQE,
                                event_bytes);
    s = c.decode(eq_image, eq_model);
    if (s == null || s.ok() || eq_model != null)
      `uvm_error("AEQE_RESERVED", "AEQE qword0 reserved bit was accepted")

    s = c.encode(aeqe, im);
    ok("aeqe re-encode for qword1 reserved red", s);
    eq_builder = new("aeqe_reserved_qword1_builder");
    s = eq_builder.deserialize(im.bytes);
    ok("aeqe qword1 reserved deserialize", s);
    s = eq_builder.put_field(8, 28, 1, 1);
    ok("aeqe qword1 reserved field", s);
    s = eq_builder.serialize(event_bytes);
    ok("aeqe qword1 reserved serialize", s);
    eq_image = make_event_image("aeqe_qword1_reserved", RDMA_IMAGE_AEQE,
                                event_bytes);
    s = c.decode(eq_image, eq_model);
    if (s == null || s.ok() || eq_model != null)
      `uvm_error("AEQE_RESERVED", "AEQE qword1 reserved bits were accepted")

    sq=rdma_hw_sqe_model::type_id::create("sq"); sq.transport=RDMA_TRANSPORT_RC; sq.qp_h=h("q",RDMA_RESOURCE_QP,'h15555);
    sq.hw_opcode=4'hd; sq.icos=5; sq.qp_sn=8'ha6; sq.dst_port=11; sq.index='h4567; sq.wrap=1; sq.sign_en=1; sq.se=1; sq.fence=2; sq.ce=2; sq.valid=1; sq.signature=8'hc7;
    re=rdma_sqe_rc_ext::type_id::create("re"); re.remote_access_valid=1; re.rkey_valid=1; re.rkey=32'hdeadbeef; re.remote_addr.value=64'h0123456789abcdef; sq.transport_ext=re;
    sg=rdma_sge::type_id::create("sg"); sg.iova.value=64'h1000; sg.length=8; sq.sges.push_back(sg); sq.sge_num=4;
    s=r.lookup('{hw_version:"rdma",image_kind:RDMA_IMAGE_SQE,object_type:"sqe",variant:"rc",opcode:0},c); ok("lookup sq",s); s=c.encode(sq,im); ok("sq encode",s); s=c.decode(im,m); ok("sq decode",s); $cast(sq2,m); s=c.encode(sq2,im2); ok("sq reencode",s); eq_bytes("sq roundtrip",im,im2);
    rq=rdma_hw_rqe_model::type_id::create("rq"); rq.target_h=h("rq",RDMA_RESOURCE_QP,1); rq.qpn='habcde; rq.qp_sn='h5a; rq.hw_opcode=9; rq.index='h3456; rq.wrap=1; rq.valid=1; rq.payload_len='h10203040; rq.signature=8'h96; rq.sge_num=2; rq.sges.push_back(sg);
    s = r.lookup(
        '{hw_version:"rdma", image_kind:RDMA_IMAGE_RQE,
          object_type:"rqe", variant:"default", opcode:0},
        c
      );
    ok("lookup rq", s);
    s = rq.set_sgb_pa_from_physical(64'h2468_acf1_3579_bc00);
    ok("rq physical sgb setter", s);
    if (rq.sgb_pa !== 55'h1234_5678_9abc_de ||
        rq.sgb_pa_as_physical() !== 64'h2468_acf1_3579_bc00)
      `uvm_error("RQE_SGB_MODEL", "physical SGB_PA did not become PA>>9")
    initial_sgb_pa = rq.sgb_pa;
    s = rq.set_sgb_pa_from_physical(64'h2468_acf1_3579_bc01);
    if (s == null || s.ok())
      `uvm_error("RQE_SGB_ALIGN", "unaligned physical SGB_PA was accepted")
    if (rq.sgb_pa !== initial_sgb_pa)
      `uvm_error("RQE_SGB_ALIGN", "rejected unaligned SGB_PA changed the model")

    // 合法 wire 值的上界恰好占满驱动拥有的 55 个 bit；与被拒绝的 64 位
    // 溢出输入分开验证，并在可表达范围顶端执行一次完整编解码往返。
    s = rq.set_sgb_pa_encoded(55'h7fff_ffff_ffff_ff);
    ok("rq maximum encoded sgb setter", s);
    if (rq.sgb_pa_as_physical() !== 64'hffff_ffff_ffff_fe00)
      `uvm_error("RQE_SGB_MAX", "maximum legal encoded SGB_PA did not round-trip")
    s = c.encode(rq, im);
    ok("rq maximum encoded wire", s);
    s = c.decode(im, m);
    ok("rq maximum encoded decode", s);
    if (m == null)
      `uvm_error("RQE_SGB_MAX", "maximum legal encoded SGB_PA decoded to null")

    previous_sgb_pa = rq.sgb_pa;
    s = rq.set_sgb_pa_encoded(64'h0080_0000_0000_0000);
    if (s == null || s.ok())
      `uvm_error("RQE_SGB_WIDTH", "encoded SGB_PA wider than 55 bits was accepted")
    if (rq.sgb_pa !== previous_sgb_pa)
      `uvm_error("RQE_SGB_WIDTH", "rejected encoded SGB_PA changed the model")

    // 在 raw 坐标和 detached copy 检查前恢复 fixture 初值，确保后续断言
    // 使用同一个稳定的物理地址期望值。
    s = rq.set_sgb_pa_encoded({9'b0, initial_sgb_pa});
    ok("rq restore encoded sgb fixture", s);
    s = c.encode(rq, im);
    ok("rq encode", s);
    s = c.decode(im, m);
    ok("rq decode", s);

    // Driver wr.h:188 把 RQE qword4[63:9] 定义为 SGB_PA；该 raw image
    // 断言锁定合法字段位置，并防止回退为整 qword 保留位。
    rqe_builder = new("rqe_sgb_red_builder");
    s = rqe_builder.deserialize(im.bytes);
    ok("rqe sgb red deserialize", s);
    s = rqe_builder.put_field(32, 9, 55, 55'h1234_5678_9abc_de);
    ok("rqe sgb red raw field", s);
    s = rqe_builder.serialize(rqe_bytes);
    ok("rqe sgb red serialize", s);
    rqe_builder.get_words(rqe_words);
    if (rqe_words.size() != 8 ||
        rqe_words[4][63:9] !== 55'h1234_5678_9abc_de ||
        rqe_words[4][8:0] !== 9'b0)
      `uvm_error("RQE_SGB_RAW", "RQE qword4 raw coordinate is incorrect")
    foreach (im.bytes[i]) im.bytes[i] = rqe_bytes[i];
    s = c.decode(im, m);
    if (s == null || !s.ok())
      `uvm_error("RQE_SGB_RAW", "RQE qword4 SGB_PA raw field was rejected")
    else begin
      $cast(rq2, m);
      if (rq2 == null || rq2.sgb_pa !== 55'h1234_5678_9abc_de ||
          rq2.sgb_pa_as_physical() !== 64'h2468_acf1_3579_bc00)
        `uvm_error("RQE_SGB_DECODE", "RQE SGB_PA detached decode mismatched")
    end

    rq2 = rdma_hw_rqe_model::type_id::create("rq_copy");
    rq2.copy(rq);
    if (rq2.sgb_pa !== rq.sgb_pa ||
        rq2.sgb_pa_as_physical() !== rq.sgb_pa_as_physical())
      `uvm_error("RQE_SGB_COPY", "RQE SGB_PA detached copy mismatched")

    // qword2 bit0 is outside SIGNATURE/SGE_NUM and must remain reserved;
    // explicit parentheses in image_check keep this rejection unambiguous.
    s = c.encode(rq, im);
    ok("rq re-encode for reserved red", s);
    rqe_builder = new("rqe_reserved_red_builder");
    s = rqe_builder.deserialize(im.bytes);
    ok("rqe reserved red deserialize", s);
    s = rqe_builder.put_field(16, 0, 1, 1);
    ok("rqe reserved red raw field", s);
    s = rqe_builder.serialize(rqe_bytes);
    ok("rqe reserved red serialize", s);
    foreach (im.bytes[i]) im.bytes[i] = rqe_bytes[i];
    s = c.decode(im, m);
    if (s == null || s.ok())
      `uvm_error("RQE_RESERVED", "RQE qword2 reserved bit was accepted")

    // qword3 and qword5..qword7 remain fully reserved; qword4 low bits are
    // also reserved because the driver consumes only SGB_PA[63:9].
    for (int unsigned reserved_qword = 3;
         reserved_qword <= 7;
         reserved_qword++) begin
      s = c.encode(rq, im);
      ok("rq re-encode for reserved strictness", s);
      rqe_builder = new("rqe_reserved_strict_builder");
      s = rqe_builder.deserialize(im.bytes);
      ok("rqe reserved strict deserialize", s);
      s = rqe_builder.put_field(reserved_qword << 3, 0, 1, 1);
      ok("rqe reserved strict raw field", s);
      s = rqe_builder.serialize(rqe_bytes);
      ok("rqe reserved strict serialize", s);
      foreach (im.bytes[i]) im.bytes[i] = rqe_bytes[i];
      s = c.decode(im, m);
      if (s == null || s.ok())
        `uvm_error("RQE_RESERVED", $sformatf(
            "RQE reserved qword %0d was accepted", reserved_qword))
      else if (m != null)
        `uvm_error("RQE_RESERVED_MODEL", $sformatf(
            "RQE reserved qword %0d published a model on failure",
            reserved_qword))
    end
    cq=rdma_hw_cqe_model::type_id::create("cq"); cq.qp_h=h("cq",RDMA_RESOURCE_QP,'h2aaaa); cq.qpn='h2aaaa; cq.wqe_index='h4567; cq.ecode=8'hf4; cq.payload_len='h10203040; cq.polarity=1; cq.rq_cqe=1; cq.wqe_wrap=1; cq.packet_opcode=8'h9a; cq.immediate_data=32'h89abcdef; cq.status=rdma_status::type_id::create("st");
    s=r.lookup('{hw_version:"rdma",image_kind:RDMA_IMAGE_CQE,object_type:"cqe",variant:"default",opcode:0},c); ok("lookup cq",s); s=c.encode(cq,im); ok("cq encode",s); s=c.decode(im,m); ok("cq decode",s);
    // The 128B CQE profile owns qword8..qword10; qword0..qword7 remain a
    // zeroed prefix in producer images and are not widened into CQE fields.
    profile_codec = rdma_hw_cqe_codec::type_id::create("queue_test_profile_cqe");
    s = profile_codec.encode_with_entry_bytes(cq, 128, profile_image);
    if (s == null || !s.ok() || profile_image == null ||
        profile_image.bytes.size() != 128 || profile_image.length != 128 ||
        profile_image.alignment != 128)
      `uvm_error("cq_128_profile", "128B CQE profile metadata is invalid")
    else begin
      profile_builder = new("queue_test_profile_builder");
      s = profile_builder.deserialize(profile_image.bytes);
      profile_builder.get_words(profile_words);
      if (s == null || !s.ok() || profile_words.size() != 16 ||
          profile_words[8][17:0] !== cq.qpn ||
          profile_words[9][31:0] !== cq.payload_len ||
          profile_words[10][63:56] !== cq.signature ||
          profile_words[0] !== 0 || profile_words[7] !== 0)
        `uvm_error("cq_128_profile_raw", "128B CQE fields are not at qword8 window")
    end
    bad = new[64]; foreach (bad[i]) bad[i]=0; bad[0]=8'h1; im.bytes.delete(); foreach (bad[i]) im.bytes.push_back(bad[i]); im.length=64; im.alignment=64; im.endian=RDMA_ENDIAN_BIG; im.image_kind=RDMA_IMAGE_CQE; im.hardware_version=1; s=c.validate_image(im); if (s==null || s.ok()) `uvm_error("reserved","reserved bits accepted");
    phase.drop_objection(this);
  endtask
endclass
