// 目录/层次：tests/unit/ queue codec 单元测试层。
// 职责：验证 SQE/RQE/CQE/CEQE/AEQE 的 registry 路由、raw 字段、保留位、
//   signature、transport overlay 与 decode/re-encode 稳定性。
// 依赖：rdma_codec_pkg、rdma_model_pkg 与 UVM；不依赖真实 Host-memory 或 PCIe。
// 所有权与生命周期：测试在 run_phase 内拥有 model/image fixture；registry 与
//   codec 仅在本地仿真生命周期内使用，不取得任何外部 backing 或句柄所有权。

class rdma_queue_codec_test extends uvm_test;
  `uvm_component_utils(rdma_queue_codec_test)

  // 功能：构造 rdma_queue_codec_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_codec_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_queue_codec_test", uvm_component parent=null);
    super.new(name,parent);
  endfunction

  // 功能：h 为 codec fixture 构造固定 Function incarnation 下的资源句柄，
  //   使不同 image kind 可用 literal kind/object_id 建立 authority。
  // 输入/输出及副作用：n 是 UVM 对象名，k/id 写入返回句柄；固定
  //   function_uid=0x1122、generation=1，不登记 resource manager 或外部账本。
  // 失败/边界：factory 无法创建对象时返回 null；本 helper 不校验 k/id 是否适合
  //   某一 codec，负例可故意传入错误 kind，并由被测入口 fail closed。
  function automatic rdma_handle h(
      string n,
      rdma_resource_kind_e k,
      int unsigned id);
    rdma_handle x;

    x = rdma_handle::type_id::create(n);
    if (x == null)
      return null;
    x.kind = k;
    x.object_id = id;
    x.function_uid = 64'h1122;
    x.generation = 1;
    return x;
  endfunction

  // 功能：ok 断言 codec 操作返回非空成功状态，以统一正常路径的 UVM 诊断。
  // 输入/输出及副作用：l 是失败报告 ID，s 是只读 status；失败时发布一个
  //   UVM_ERROR，成功时无副作用，不修改 status、model 或 image。
  // 失败/边界：s=null 与 s.non-OK 都报告；null 使用 literal "null"，非成功
  //   状态使用 convert2string，函数不终止 run_phase 或伪造后续成功。
  function automatic void ok(string l, rdma_status s);
    if (s == null || !s.ok())
      `uvm_error(l, s == null ? "null" : s.convert2string())
  endfunction

  // 功能：eq_bytes 比较两个完整 hardware image 的长度与四态逐字节内容，
  //   锁定 decode/re-encode 后的 raw ABI 不漂移。
  // 输入/输出及副作用：l 是 UVM report ID，a/b 为只读 image；每个不等字节
  //   发布带索引的 UVM_ERROR，不修改输入或外部 backing。
  // 失败/边界：任一 image 为 null 或长度不同仅报告一次 image mismatch 并返回；
  //   长度一致时继续报告全部差异字节，便于同时定位多个 wire 坐标。
  function automatic void eq_bytes(string l, rdma_hw_image a, rdma_hw_image b);
    if (a == null || b == null || a.bytes.size() != b.bytes.size()) begin
      `uvm_error(l, "image mismatch")
      return;
    end
    foreach (a.bytes[i]) begin
      if (a.bytes[i] !== b.bytes[i])
        `uvm_error(l, $sformatf("byte %0d", i))
    end
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

  // 功能：expect_aeqe_encode_accepted 验证一个已安装 class-correct
  //   target/profile authority 的 canonical AEQE 能生成完整 16B image。
  // 输入/输出及副作用：label、codec、event_model 为输入；函数调用
  //   真实 encode 并通过 UVM error 发布失败，不修改模型或外部 ring。
  // 失败/边界：status 为 null/失败、image 为 null 或长度不是
  //   RDMA_AEQE_BYTES 都记录错误；该 helper 不放宽 codec 校验。
  function automatic void expect_aeqe_encode_accepted(
      string label,
      rdma_codec_base codec,
      rdma_hw_aeqe_model event_model
  );
    rdma_hw_image encoded_image;
    rdma_status status;

    status = codec.encode(event_model, encoded_image);
    if (status == null || !status.ok() || encoded_image == null ||
        encoded_image.bytes.size() != RDMA_AEQE_BYTES)
      `uvm_error(label, $sformatf(
          "legal canonical AEQE was rejected: %s",
          status == null ? "<null>" : status.message))
  endfunction

  // 功能：expect_aeqe_encode_rejected 验证 canonical AEQE 的单一
  //   class-cross/subselector 污染被 fail-closed，且不发布半成品 image。
  // 输入/输出及副作用：label、codec、event_model 为输入；函数只
  //   调用真实 encode 并通过 UVM error 报告结果，不取得句柄所有权。
  // 失败/边界：encode 返回 null/success 或拒绝后 image 非 null
  //   均为契约失败；输入模型必须在调用前完成合法基线配置。
  function automatic void expect_aeqe_encode_rejected(
      string label,
      rdma_codec_base codec,
      rdma_hw_aeqe_model event_model
  );
    rdma_hw_image rejected_image;
    rdma_status status;

    rejected_image = rdma_hw_image::type_id::create(
        "aeqe_rejected_sentinel");
    status = codec.encode(event_model, rejected_image);
    if (status == null || status.ok())
      `uvm_error(label, "class-cross canonical AEQE was accepted")
    if (rejected_image != null)
      `uvm_error(label, "rejected canonical AEQE published an image")
  endfunction

  // 功能：expect_aeqe_raw_decode_unresolved 从独立构造的 16B raw image
  //   解码 QP/SRQ/CQ/EQ/diagnostic 事件，验证观测值不伪造 route target。
  // 输入/输出及副作用：label、codec、ecode 及三类 literal owner ID
  //   为输入；函数构造本地 builder/image，调用真实 decode 并通过
  //   UVM error 报告结果，不安装 profile authority 或修改外部资源。
  // 失败/边界：builder/decode 失败、raw qword/typed ID 不完整、
  //   profile valid 被误置或 target_h 非 null 均报错；保留位非零由 codec 拒绝。
  function automatic void expect_aeqe_raw_decode_unresolved(
      string label,
      rdma_codec_base codec,
      bit [7:0] ecode,
      bit [17:0] qpn,
      bit [18:0] cqn_eqn,
      bit [11:0] srfqn
  );
    rdma_hw_qword_builder builder;
    bit [63:0] words[];
    byte unsigned payload[];
    rdma_hw_image image;
    rdma_hw_model decoded_model;
    rdma_hw_aeqe_model decoded_event;
    rdma_status status;

    builder = new({label, "_builder"});
    status = builder.reset(RDMA_AEQE_BYTES);
    if (status == null || !status.ok()) begin
      `uvm_error(label, "raw AEQE builder reset failed")
      return;
    end

    status = builder.put_field(
        RDMA_AEQE_VALID_WORD_BYTE_OFFSET,
        RDMA_AEQE_VALID_LSB,
        RDMA_AEQE_VALID_WIDTH,
        1'b1);
    if (status != null && status.ok())
      status = builder.put_field(
          RDMA_AEQE_ECODE_WORD_BYTE_OFFSET,
          RDMA_AEQE_ECODE_LSB,
          RDMA_AEQE_ECODE_WIDTH,
          ecode);
    if (status != null && status.ok())
      status = builder.put_field(
          RDMA_AEQE_QPN_WORD_BYTE_OFFSET,
          RDMA_AEQE_QPN_LSB,
          RDMA_AEQE_QPN_WIDTH,
          qpn);
    if (status != null && status.ok())
      status = builder.put_field(
          RDMA_AEQE_CQN_EQN_HIGH_WORD_BYTE_OFFSET,
          RDMA_AEQE_CQN_EQN_HIGH_LSB,
          RDMA_AEQE_CQN_EQN_HIGH_WIDTH,
          cqn_eqn >> RDMA_AEQE_CQN_EQN_LSHIFT);
    if (status != null && status.ok())
      status = builder.put_field(
          RDMA_AEQE_CQN_EQN_LOW_WORD_BYTE_OFFSET,
          RDMA_AEQE_CQN_EQN_LOW_LSB,
          RDMA_AEQE_CQN_EQN_LOW_WIDTH,
          cqn_eqn[5:0]);
    if (status != null && status.ok())
      status = builder.put_field(
          RDMA_AEQE_SRFQN_WORD_BYTE_OFFSET,
          RDMA_AEQE_SRFQN_LSB,
          RDMA_AEQE_SRFQN_WIDTH,
          srfqn);
    if (status == null || !status.ok()) begin
      `uvm_error(label, "raw AEQE literal field construction failed")
      return;
    end

    status = builder.serialize(payload);
    if (status == null || !status.ok()) begin
      `uvm_error(label, "raw AEQE literal serialization failed")
      return;
    end
    builder.get_words(words);
    image = make_event_image({label, "_image"}, RDMA_IMAGE_AEQE, payload);
    status = codec.decode(image, decoded_model);
    if (status == null || !status.ok() ||
        !$cast(decoded_event, decoded_model)) begin
      `uvm_error(label, $sformatf(
          "raw AEQE decode failed: %s",
          status == null ? "<null>" : status.message))
      return;
    end

    if (!decoded_event.raw_qwords_valid || words.size() != 2 ||
        decoded_event.raw_qword0 !== words[0] ||
        decoded_event.raw_qword1 !== words[1] ||
        decoded_event.ecode !== ecode || decoded_event.qpn !== qpn ||
        decoded_event.logical_cqn_eqn() !== cqn_eqn ||
        decoded_event.srfqn !== srfqn)
      `uvm_error(label, "raw AEQE decode lost typed or qword evidence")
    if (decoded_event.profile_class_valid ||
        decoded_event.profile_owner_valid)
      `uvm_error(label, "raw AEQE decode invented profile authority")
    if (decoded_event.target_h != null)
      `uvm_error(label, "raw AEQE decode invented a route target")
  endfunction

  // 功能：expect_aeqe_raw_qp_state_replay 从 literal wire 字段构造
  //   QP_ST=6/7 的 AEQE，验证 detached decode 与显式授权后的原样重放。
  // 输入/输出及副作用：label、codec、qp_state 为输入；函数创建本地
  //   builder/image/model，安装 QP target/profile authority 并调用真实 codec，
  //   不修改 registry、queue runtime 或外部 backing。
  // 失败/边界：仅接受 qp_state=6/7；decode 必须保持 target_h=null、两个
  //   raw qword 与 typed state，authority/replay/encode 任一步失败或重编码
  //   不是完整 16B byte-exact image 时报告同一合同错误并停止该用例。
  function automatic void expect_aeqe_raw_qp_state_replay(
      string label,
      rdma_codec_base codec,
      bit [2:0] qp_state
  );
    rdma_hw_qword_builder builder;
    bit [63:0] literal_words[];
    byte unsigned payload[];
    rdma_hw_image raw_image;
    rdma_hw_image replay_image;
    rdma_hw_model decoded_model;
    rdma_hw_aeqe_model decoded_event;
    rdma_status status;

    if (!(qp_state inside {3'd6, 3'd7})) begin
      `uvm_error(label, "raw QP-state replay helper received a canonical state")
      return;
    end

    builder = new({label, "_builder"});
    status = builder.reset(RDMA_AEQE_BYTES);
    if (status != null && status.ok())
      status = builder.put_field(
          RDMA_AEQE_VALID_WORD_BYTE_OFFSET,
          RDMA_AEQE_VALID_LSB,
          RDMA_AEQE_VALID_WIDTH,
          1'b1);
    if (status != null && status.ok())
      status = builder.put_field(
          RDMA_AEQE_QP_ST_WORD_BYTE_OFFSET,
          RDMA_AEQE_QP_ST_LSB,
          RDMA_AEQE_QP_ST_WIDTH,
          qp_state);
    if (status != null && status.ok())
      status = builder.put_field(
          RDMA_AEQE_ECODE_WORD_BYTE_OFFSET,
          RDMA_AEQE_ECODE_LSB,
          RDMA_AEQE_ECODE_WIDTH,
          8'h5a);
    if (status != null && status.ok())
      status = builder.put_field(
          RDMA_AEQE_QPN_WORD_BYTE_OFFSET,
          RDMA_AEQE_QPN_LSB,
          RDMA_AEQE_QPN_WIDTH,
          18'h106);
    if (status != null && status.ok())
      status = builder.put_field(
          RDMA_AEQE_URC_REMOTE_ECODE_WORD_BYTE_OFFSET,
          RDMA_AEQE_URC_REMOTE_ECODE_LSB,
          RDMA_AEQE_URC_REMOTE_ECODE_WIDTH,
          8'h6b);
    if (status != null && status.ok())
      status = builder.put_field(
          RDMA_AEQE_WQE_WRAP_WORD_BYTE_OFFSET,
          RDMA_AEQE_WQE_WRAP_LSB,
          RDMA_AEQE_WQE_WRAP_WIDTH,
          1'b1);
    if (status != null && status.ok())
      status = builder.put_field(
          RDMA_AEQE_WQE_INDEX_WORD_BYTE_OFFSET,
          RDMA_AEQE_WQE_INDEX_LSB,
          RDMA_AEQE_WQE_INDEX_WIDTH,
          23'h456789);
    if (status == null || !status.ok()) begin
      `uvm_error(label, "raw QP-state literal construction failed")
      return;
    end

    status = builder.serialize(payload);
    builder.get_words(literal_words);
    if (status == null || !status.ok() || literal_words.size() != 2) begin
      `uvm_error(label, "raw QP-state literal serialization failed")
      return;
    end
    raw_image = make_event_image(
        {label, "_image"}, RDMA_IMAGE_AEQE, payload);
    decoded_model = null;
    status = codec.decode(raw_image, decoded_model);
    if (status == null || !status.ok() ||
        !$cast(decoded_event, decoded_model)) begin
      `uvm_error(label, $sformatf(
          "raw QP-state decode failed: %s",
          status == null ? "<null>" : status.message))
      return;
    end
    if (decoded_event.target_h != null ||
        decoded_event.profile_class_valid ||
        decoded_event.profile_owner_valid ||
        !decoded_event.raw_qwords_valid ||
        decoded_event.qp_state !== qp_state ||
        decoded_event.raw_qword0 !== literal_words[0] ||
        decoded_event.raw_qword1 !== literal_words[1]) begin
      `uvm_error(label, "raw QP-state decode lost detached wire evidence")
      return;
    end

    decoded_event.target_h = h(
        {label, "_qp"}, RDMA_RESOURCE_QP, 32'h4100_0106);
    status = decoded_event.set_profile_owner_authority(
        RDMA_AEQE_EVENT_QP, RDMA_RESOURCE_QP);
    if (status != null && status.ok())
      status = decoded_event.authorize_raw_replay();
    if (status == null || !status.ok()) begin
      `uvm_error(label, "raw QP-state replay authority setup failed")
      return;
    end
    replay_image = null;
    status = codec.encode(decoded_event, replay_image);
    if (status == null || !status.ok() || replay_image == null ||
        replay_image.bytes.size() != RDMA_AEQE_BYTES) begin
      `uvm_error(label, $sformatf(
          "authorized raw QP-state replay failed: %s",
          status == null ? "<null>" : status.message))
      return;
    end
    eq_bytes({label, "_BYTE_EXACT"}, raw_image, replay_image);
  endfunction

  // 功能：在 rdma_queue_codec_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    rdma_codec_registry r; rdma_status s; rdma_codec_base c; rdma_hw_image im,im2; rdma_hw_model m;
    rdma_hw_sqe_model sq;
    rdma_hw_sqe_model sq2;
    rdma_hw_sqe_model sq_empty;
    rdma_hw_sqe_model sq_atomic;
    rdma_hw_rqe_model rq;
    rdma_hw_rqe_model rq2;
    rdma_hw_rqe_model rq_external_mismatch;
    rdma_hw_rqe_model rq_forged_external;
    rdma_hw_rqe_model rq_fresh_raw;
    rdma_hw_rqe_model rq_count_overflow;
    rdma_hw_rqe_model rq_payload_mismatch;
    rdma_hw_rqe_model rq_zero_sentinel;
    rdma_hw_rqe_model rq_zero_filtered;
    rdma_hw_rqe_model rq_inline, rq_inline_decoded;
    rdma_hw_rqe_model rq_length;
    rdma_hw_cqe_model cq, cq2;
    rdma_hw_ceqe_model ceqe;
    rdma_hw_ceqe_model ceqe_urc;
    rdma_hw_ceqe_model ceqe_copy;
    rdma_hw_ceqe_model ceqe_decoded;
    rdma_hw_aeqe_model aeqe;
    rdma_hw_aeqe_model aeqe_copy;
    rdma_hw_aeqe_model aeqe_decoded;
    rdma_sqe_rc_ext re;
    rdma_sge sg;
    rdma_sge rq_sg0;
    rdma_sge rq_sg1;
    rdma_sge rq_sg2;
    rdma_sge rq_sg3;
    rdma_sge rq_length_sg;
    rdma_sge rq_zero_sg;
    rdma_sge rq_zero_valid_sg;
    rdma_sge rq_external_sg1;
    rdma_sge rq_external_sg2;
    rdma_sge rq_zero_sentinel_sg;
    byte unsigned bad[];
    byte unsigned no_sgb[$];
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
    rdma_hw_image rq_bad_opcode_image;
    rdma_hw_model eq_model;
    rdma_hw_aeqe_model decoded_aeqe;
    bit [54:0] initial_sgb_pa;
    bit [54:0] previous_sgb_pa;
    bit [7:0] expected_rqe_signature;
    byte unsigned rqe_descriptor_bytes[$];
    byte unsigned forged_rqe_descriptor_bytes[$];
    byte unsigned short_rqe_descriptor_bytes[$];
    rdma_hw_image rqe_bad_signature_image;
    rdma_hw_rqe_codec rqe_codec;
    phase.raise_objection(this);
    r=rdma_codec_registry::type_id::create("r"); s=rdma_register_queue_codecs(r); ok("register",s);
    // 设计说明：CQ handle.object_id 是 resource manager 分配的 global incarnation，
    // cqn 是 Function-local CQ ID；二者不共享命名空间，model/codec 只能校验 handle
    // kind 和各字段宽度，完整 identity 由 queue-data attachment 边界完成。
    ceqe=rdma_hw_ceqe_model::type_id::create("ceqe_local_cqn");
    ceqe.cq_h=h("ceqe_cq",RDMA_RESOURCE_CQ,32'h3000_0002);
    s=ceqe.set_profile_transport_authority(RDMA_TRANSPORT_RC);
    ok("ceqe local cqn profile authority", s);
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
      s = ceqe_decoded.set_profile_transport_authority(RDMA_TRANSPORT_URC);
      ok("ceqe urc raw profile authority", s);
      s = ceqe_decoded.authorize_raw_qword1_replay();
      ok("ceqe urc raw replay authority", s);
      s = c.encode(ceqe_decoded, eq_image_copy);
      ok("ceqe urc raw decode re-encode", s);
      eq_bytes("ceqe urc raw decode byte equivalence", eq_image,
               eq_image_copy);
    end

    // RED：驱动 xtrdma_get_ceqe_info() 不检查 URC_FLAG，仍会无条件读取
    // qword1 的 URC overlay。RC selector=0 但 overlay 非零时，当前 codec
    // 把这些合法 wire bits 当成 reserved；修复后必须保留并原样回编码。
    eq_builder = new("ceqe_rc_inactive_overlay_red_builder");
    s = eq_builder.reset(RDMA_CEQE_BYTES);
    ok("ceqe rc inactive overlay reset", s);
    s = eq_builder.put_field(0, 63, 1, 1);
    s = eq_builder.put_field(0, 40, 21, 21'h12345);
    s = eq_builder.put_field(0, 16, 21, 21'h23456);
    s = eq_builder.put_field(0, 8, 8, 8'h41);
    s = eq_builder.put_field(0, 0, 8, 8'h52);
    s = eq_builder.put_field(8, 56, 2, 2'b01);
    s = eq_builder.put_field(8, 48, 8, 8'h5A);
    s = eq_builder.put_field(8, 47, 1, 1);
    s = eq_builder.put_field(8, 32, 15, 15'h1234);
    ok("ceqe rc inactive overlay fields", s);
    s = eq_builder.serialize(event_bytes);
    ok("ceqe rc inactive overlay serialize", s);
    eq_image = make_event_image(
        "ceqe_rc_inactive_overlay_red", RDMA_IMAGE_CEQE, event_bytes);
    s = c.decode(eq_image, eq_model);
    if (s == null || !s.ok() || !$cast(ceqe_decoded, eq_model) ||
        ceqe_decoded.urc_flag !== 1'b0 ||
        ceqe_decoded.urc_abnormal_cqe_type !== 2'b01 ||
        ceqe_decoded.urc_abnormal_cqe_remote_ecode !== 8'h5A ||
        ceqe_decoded.urc_abnormal_cqe_wqe_idx_wrap !== 1'b1 ||
        ceqe_decoded.urc_abnormal_cqe_wqe_idx !== 15'h1234)
      `uvm_error("CEQE_INACTIVE_OVERLAY_RED",
                 $sformatf("inactive CEQE overlay was rejected or dropped: %s",
                           s == null ? "<null>" : s.message))
    else begin
      s = ceqe_decoded.set_profile_transport_authority(RDMA_TRANSPORT_RC);
      ok("ceqe rc inactive profile authority", s);
      s = ceqe_decoded.authorize_raw_qword1_replay();
      ok("ceqe rc inactive raw replay authority", s);
      s = c.encode(ceqe_decoded, eq_image_copy);
      ok("ceqe inactive overlay raw decode re-encode", s);
      eq_bytes("ceqe inactive overlay raw byte equivalence", eq_image,
               eq_image_copy);
    end

    s = r.lookup(
        '{hw_version:"rdma", image_kind:RDMA_IMAGE_AEQE,
          object_type:"aeqe", variant:"default", opcode:0},
        c);
    ok("lookup aeqe", s);

    // A-CLASS-CROSS RED：每一行先经过本 class 的 canonical 正例，
    // 再只污染一个其他 class/subselector 拥有的字段。特别覆盖
    // qp_state/srfq_en/overflow/cq_invalid，防止无条件 FIELD_GET 重新
    // 被误当成 union-wide canonical write authority。
    aeqe = rdma_hw_aeqe_model::type_id::create(
        "aeqe_diagnostic_qpn_cross");
    aeqe.target_h = h(
        "aeqe_diagnostic_owner", RDMA_RESOURCE_FUNCTION, 32'h4100_0001);
    aeqe.valid = 1'b1;
    aeqe.ecode = 8'hff;
    s = aeqe.set_profile_owner_authority(
        RDMA_AEQE_EVENT_DIAGNOSTIC, RDMA_RESOURCE_FUNCTION);
    ok("aeqe diagnostic cross authority", s);
    expect_aeqe_encode_accepted("AEQE_DIAGNOSTIC_BASELINE", c, aeqe);
    aeqe.qp_state = 3'd1;
    expect_aeqe_encode_rejected("AEQE_DIAGNOSTIC_QP_STATE_CROSS", c, aeqe);
    aeqe.qp_state = '0;
    aeqe.overflow_flag = 1'b1;
    expect_aeqe_encode_rejected("AEQE_CANONICAL_OVERFLOW_CROSS", c, aeqe);
    aeqe.overflow_flag = 1'b0;
    aeqe.qpn = 18'h1;
    expect_aeqe_encode_rejected("AEQE_DIAGNOSTIC_QPN_CROSS", c, aeqe);
    aeqe.qpn = '0;
    aeqe.packet_opcode = 8'ha1;
    expect_aeqe_encode_rejected(
        "AEQE_DIAGNOSTIC_PACKET_OPCODE_CROSS", c, aeqe);

    aeqe = rdma_hw_aeqe_model::type_id::create("aeqe_qp_srfqn_cross");
    aeqe.target_h = h("aeqe_qp_owner", RDMA_RESOURCE_QP, 32'h4100_0002);
    aeqe.valid = 1'b1;
    aeqe.qp_state = 3'd5;
    aeqe.ecode = 8'h5a;
    aeqe.qpn = 18'h102;
    s = aeqe.set_profile_owner_authority(
        RDMA_AEQE_EVENT_QP, RDMA_RESOURCE_QP);
    ok("aeqe qp cross authority", s);
    expect_aeqe_encode_accepted("AEQE_QP_BASELINE", c, aeqe);
    aeqe.srfq_en = 1'b1;
    expect_aeqe_encode_rejected("AEQE_QP_SRFQ_FLAG_CROSS", c, aeqe);
    aeqe.srfq_en = 1'b0;
    aeqe.cq_invalid_flag = 1'b1;
    expect_aeqe_encode_rejected("AEQE_QP_CQ_INVALID_CROSS", c, aeqe);
    aeqe.cq_invalid_flag = 1'b0;
    aeqe.srfqn = 12'h1;
    expect_aeqe_encode_rejected("AEQE_QP_SRFQN_CROSS", c, aeqe);
    aeqe.srfqn = '0;
    aeqe.packet_opcode = 8'ha2;
    expect_aeqe_encode_rejected(
        "AEQE_QP_NON_URC_PACKET_OPCODE_CROSS", c, aeqe);

    aeqe = rdma_hw_aeqe_model::type_id::create("aeqe_srq_qpn_cross");
    aeqe.target_h = h("aeqe_srq_owner", RDMA_RESOURCE_SRQ, 32'h4100_0003);
    aeqe.valid = 1'b1;
    aeqe.ecode = 8'h78;
    aeqe.srfq_en = 1'b0;
    aeqe.srfqn = 12'h123;
    aeqe.srfqe_idx = 16'h4567;
    s = aeqe.set_profile_owner_authority(
        RDMA_AEQE_EVENT_SRQ, RDMA_RESOURCE_SRQ);
    ok("aeqe srq cross authority", s);
    expect_aeqe_encode_accepted("AEQE_SRQ_SELECTOR_INDEPENDENT", c, aeqe);
    aeqe.srfq_en = 1'b1;
    expect_aeqe_encode_accepted("AEQE_SRQ_OPTIONAL_SRFQ_FLAG", c, aeqe);
    aeqe.srfq_en = 1'b0;
    aeqe.qpn = 18'h1;
    expect_aeqe_encode_rejected("AEQE_SRQ_QPN_CROSS", c, aeqe);
    aeqe.qpn = '0;
    aeqe.packet_opcode = 8'ha3;
    expect_aeqe_encode_rejected(
        "AEQE_SRQ_PACKET_OPCODE_CROSS", c, aeqe);

    aeqe = rdma_hw_aeqe_model::type_id::create("aeqe_cq_srfqn_cross");
    aeqe.target_h = h("aeqe_cq_owner", RDMA_RESOURCE_CQ, 32'h4100_0004);
    aeqe.valid = 1'b1;
    aeqe.cq_invalid_flag = 1'b1;
    aeqe.ecode = 8'hf3;
    aeqe.cqn_eqn_high = 13'h12;
    aeqe.cqn_eqn_low = 6'h03;
    s = aeqe.set_profile_owner_authority(
        RDMA_AEQE_EVENT_CQ, RDMA_RESOURCE_CQ);
    ok("aeqe cq cross authority", s);
    expect_aeqe_encode_accepted("AEQE_CQ_BASELINE", c, aeqe);
    aeqe.srfqn = 12'h1;
    expect_aeqe_encode_rejected("AEQE_CQ_SRFQN_CROSS", c, aeqe);
    aeqe.srfqn = '0;
    aeqe.packet_opcode = 8'hb4;
    expect_aeqe_encode_accepted(
        "AEQE_CQ_PACKET_OPCODE_POSITIVE", c, aeqe);

    aeqe = rdma_hw_aeqe_model::type_id::create("aeqe_eq_qpn_cross");
    aeqe.target_h = h("aeqe_ceq_owner", RDMA_RESOURCE_CEQ, 32'h4100_0005);
    aeqe.valid = 1'b1;
    aeqe.ecode = 8'hf7;
    aeqe.cqn_eqn_high = 13'h23;
    aeqe.cqn_eqn_low = 6'h04;
    s = aeqe.set_profile_owner_authority(
        RDMA_AEQE_EVENT_EQ, RDMA_RESOURCE_CEQ);
    ok("aeqe eq cross authority", s);
    expect_aeqe_encode_accepted("AEQE_EQ_BASELINE", c, aeqe);
    aeqe.qpn = 18'h1;
    expect_aeqe_encode_rejected("AEQE_EQ_QPN_CROSS", c, aeqe);
    aeqe.qpn = '0;
    aeqe.packet_opcode = 8'ha5;
    expect_aeqe_encode_rejected(
        "AEQE_EQ_PACKET_OPCODE_CROSS", c, aeqe);

    aeqe = rdma_hw_aeqe_model::type_id::create("aeqe_tx_flush_qpn_cross");
    aeqe.target_h = h(
        "aeqe_tx_flush_owner", RDMA_RESOURCE_FUNCTION, 32'h4100_0006);
    aeqe.valid = 1'b1;
    aeqe.ecode = 8'h07;
    s = aeqe.set_profile_owner_authority(
        RDMA_AEQE_EVENT_FLUSH, RDMA_RESOURCE_FUNCTION);
    ok("aeqe tx flush cross authority", s);
    expect_aeqe_encode_accepted("AEQE_TX_FLUSH_BASELINE", c, aeqe);
    aeqe.qpn = 18'h1;
    expect_aeqe_encode_rejected("AEQE_TX_FLUSH_OBJECT_CROSS", c, aeqe);
    aeqe.qpn = '0;
    aeqe.packet_opcode = 8'ha6;
    expect_aeqe_encode_rejected(
        "AEQE_TX_FLUSH_PACKET_OPCODE_CROSS", c, aeqe);

    aeqe = rdma_hw_aeqe_model::type_id::create(
        "aeqe_qp_flush_packet_opcode_cross");
    aeqe.target_h = h(
        "aeqe_qp_flush_owner", RDMA_RESOURCE_QP, 32'h4100_0008);
    aeqe.valid = 1'b1;
    aeqe.ecode = 8'h08;
    aeqe.qpn = 18'h108;
    s = aeqe.set_profile_owner_authority(
        RDMA_AEQE_EVENT_FLUSH, RDMA_RESOURCE_QP);
    ok("aeqe qp flush cross authority", s);
    expect_aeqe_encode_accepted("AEQE_QP_FLUSH_BASELINE", c, aeqe);
    aeqe.packet_opcode = 8'ha7;
    expect_aeqe_encode_rejected(
        "AEQE_QP_FLUSH_PACKET_OPCODE_CROSS", c, aeqe);

    aeqe = rdma_hw_aeqe_model::type_id::create("aeqe_urc_subselector_cross");
    aeqe.target_h = h("aeqe_urc_owner", RDMA_RESOURCE_QP, 32'h4100_0007);
    aeqe.valid = 1'b1;
    aeqe.qp_state = 3'd5;
    aeqe.ecode = 8'h5a;
    aeqe.qpn = 18'h107;
    aeqe.urc_flag = 1'b1;
    s = aeqe.set_profile_owner_authority(
        RDMA_AEQE_EVENT_QP, RDMA_RESOURCE_QP);
    ok("aeqe urc cross authority", s);
    expect_aeqe_encode_accepted("AEQE_URC_NORMAL_BASELINE", c, aeqe);
    aeqe.packet_opcode = 8'ha8;
    expect_aeqe_encode_rejected(
        "AEQE_QP_URC_SUBTYPE0_PACKET_OPCODE_CROSS", c, aeqe);
    aeqe.urc_abnormal_cqe_type = 2'b01;
    expect_aeqe_encode_accepted(
        "AEQE_QP_URC_SUBTYPE1_PACKET_OPCODE_POSITIVE", c, aeqe);
    aeqe.urc_abnormal_cqe_type = 2'b10;
    expect_aeqe_encode_accepted(
        "AEQE_QP_URC_SUBTYPE2_PACKET_OPCODE_POSITIVE", c, aeqe);
    aeqe.packet_opcode = '0;
    aeqe.urc_abnormal_cqe_type = 2'b00;
    aeqe.urc_remote_ecode = 8'h1;
    expect_aeqe_encode_rejected("AEQE_URC_NORMAL_PAYLOAD_CROSS", c, aeqe);
    aeqe.urc_remote_ecode = 8'h0;
    aeqe.urc_abnormal_cqe_type = 2'b11;
    expect_aeqe_encode_rejected("AEQE_URC_INVALID_SUBTYPE", c, aeqe);

    // F4 RED：standalone raw decode 只发布物理观测快照。五类事件
    // 均不安装 profile authority，也不伪造 generation=1 的 QP target。
    expect_aeqe_raw_decode_unresolved(
        "AEQE_RAW_QP_UNRESOLVED", c, 8'h5a, 18'h101, 19'h0, 12'h0);
    expect_aeqe_raw_decode_unresolved(
        "AEQE_RAW_SRQ_UNRESOLVED", c, 8'h78, 18'h0, 19'h0, 12'h102);
    expect_aeqe_raw_decode_unresolved(
        "AEQE_RAW_CQ_UNRESOLVED", c, 8'hf3, 18'h0, 19'h103, 12'h0);
    expect_aeqe_raw_decode_unresolved(
        "AEQE_RAW_EQ_UNRESOLVED", c, 8'hf7, 18'h0, 19'h104, 12'h0);
    expect_aeqe_raw_decode_unresolved(
        "AEQE_RAW_DIAGNOSTIC_UNRESOLVED", c, 8'hff,
        18'h0, 19'h0, 12'h0);
    expect_aeqe_raw_qp_state_replay(
        "AEQE_RAW_QP_STATE_6", c, 3'd6);
    expect_aeqe_raw_qp_state_replay(
        "AEQE_RAW_QP_STATE_7", c, 3'd7);

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
      decoded_aeqe.target_h = h(
        "decoded_aeqe_function", RDMA_RESOURCE_FUNCTION, 32'h4000_00ff);
      s = decoded_aeqe.set_profile_owner_authority(
        RDMA_AEQE_EVENT_DIAGNOSTIC, RDMA_RESOURCE_FUNCTION);
      ok("aeqe raw diagnostic authority", s);
      s = decoded_aeqe.authorize_raw_replay();
      ok("aeqe raw diagnostic replay authority", s);
      s = c.encode(decoded_aeqe, eq_image_copy);
      ok("aeqe raw decode re-encode", s);
      eq_bytes("aeqe raw decode byte equivalence", eq_image,
               eq_image_copy);
    end

    // RED：event.c 对 AEQE 的 URC abnormal、remote ecode 与 SRFQ 坐标也
    // 无条件 FIELD_GET。两个 selector 都关闭时，raw decode 必须保留这些合法
    // wire bits，但没有 profile/owner authority 的 canonical encode 不能重写它们。
    eq_builder = new("aeqe_inactive_overlay_red_builder");
    s = eq_builder.reset(RDMA_AEQE_BYTES);
    ok("aeqe inactive overlay reset", s);
    s = eq_builder.put_field(0, 63, 1, 1);
    s = eq_builder.put_field(0, 60, 3, 3'd5);
    s = eq_builder.put_field(0, 54, 2, 2'b01);
    s = eq_builder.put_field(0, 40, 13, 13'h345);
    s = eq_builder.put_field(0, 32, 8, 8'h22);
    s = eq_builder.put_field(0, 24, 8, 8'h33);
    s = eq_builder.put_field(0, 18, 6, 6'h12);
    s = eq_builder.put_field(0, 0, 18, 18'h23456);
    s = eq_builder.put_field(8, 56, 8, 8'h6B);
    s = eq_builder.put_field(8, 55, 1, 1);
    s = eq_builder.put_field(8, 32, 23, 23'h456789);
    s = eq_builder.put_field(8, 16, 12, 12'h789);
    s = eq_builder.put_field(8, 0, 16, 16'hBEEF);
    ok("aeqe inactive overlay fields", s);
    s = eq_builder.serialize(event_bytes);
    ok("aeqe inactive overlay serialize", s);
    eq_image = make_event_image(
        "aeqe_inactive_overlay_red", RDMA_IMAGE_AEQE, event_bytes);
    s = c.decode(eq_image, eq_model);
    if (s == null || !s.ok() || !$cast(decoded_aeqe, eq_model) ||
        decoded_aeqe.srfq_en !== 1'b0 ||
        decoded_aeqe.urc_flag !== 1'b0 ||
        decoded_aeqe.urc_abnormal_cqe_type !== 2'b01 ||
        decoded_aeqe.urc_remote_ecode !== 8'h6B ||
        decoded_aeqe.wqe_wrap !== 1'b1 ||
        decoded_aeqe.wqe_index !== 23'h456789 ||
        decoded_aeqe.srfqn !== 12'h789 ||
        decoded_aeqe.srfqe_idx !== 16'hBEEF)
      `uvm_error("AEQE_INACTIVE_OVERLAY_RED",
                 $sformatf("inactive AEQE overlay was rejected or dropped: %s",
                           s == null ? "<null>" : s.message))
    else begin
      // RED：raw decode 只能保留 observation；未安装 profile/owner authority
      // 时，普通 canonical encode 必须拒绝，不能把 inactive union bits 当成
      // 当前调用方的写权限。显式 raw replay seam 在 GREEN 阶段单独验证。
      s = c.encode(decoded_aeqe, eq_image_copy);
      if (s == null || s.ok())
        `uvm_error("AEQE_INACTIVE_CANONICAL_AUTHORITY",
                   "AEQE canonical encode accepted unauthenticated overlay")

      decoded_aeqe.target_h = h(
          "decoded_aeqe_qp", RDMA_RESOURCE_QP, 32'h4000_0033);
      s = decoded_aeqe.set_profile_owner_authority(
        RDMA_AEQE_EVENT_QP, RDMA_RESOURCE_QP);
      ok("aeqe raw qp authority", s);
      s = decoded_aeqe.authorize_raw_replay();
      ok("aeqe raw qp replay authority", s);
      s = c.encode(decoded_aeqe, eq_image_copy);
      ok("aeqe inactive overlay raw replay", s);
      eq_bytes("aeqe inactive overlay raw replay bytes", eq_image,
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
    s = ceqe.set_profile_transport_authority(RDMA_TRANSPORT_RC);
    ok("ceqe rc profile authority", s);
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
    s = ceqe_urc.set_profile_transport_authority(RDMA_TRANSPORT_URC);
    ok("ceqe urc profile authority", s);
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

    // RED：event.c 的 raw parser 会观察两套 CEQE 坐标，但 RC routed profile
    //   并不拥有 URC-only 字段。canonical encode 必须拒绝该字段，不能把
    //   raw observation union mask 当成可写 ownership。
    ceqe.urc_sq_cqe_valid = 1'b1;
    s = c.encode(ceqe, im);
    if (s == null || s.ok())
      `uvm_error("CEQE_RC_INACTIVE_OVERLAY",
                 "RC CEQE accepted a URC-owned field")
    ceqe.urc_sq_cqe_valid = 1'b0;
    ceqe_urc.cq_pi = 16'h1;
    s = c.encode(ceqe_urc, im);
    if (s == null || s.ok())
      `uvm_error("CEQE_ALIAS_CONFLICT",
                 "CEQE silently merged conflicting RC/URC alias fields")
    ceqe_urc.cq_pi = 16'h0;

    // AEQE canonical round-trip 只携带 QP class 真正消费的 QPN 和
    // URC abnormal payload。diagnostic/CQ/SRQ 的物理 overlay 完整性已由
    // 上方独立 raw image + explicit replay 覆盖，不再冒充 canonical 写权。
    s = r.lookup(
        '{hw_version:"rdma", image_kind:RDMA_IMAGE_AEQE,
          object_type:"aeqe", variant:"default", opcode:0},
        c);
    ok("lookup aeqe for roundtrip", s);
    aeqe = rdma_hw_aeqe_model::type_id::create("aeqe_roundtrip");
    aeqe.target_h = h("aeqe_qp", RDMA_RESOURCE_QP, 32'h4000_0001);
    aeqe.valid = 1'b1;
    aeqe.qp_state = 3'd5;
    aeqe.urc_flag = 1'b1;
    aeqe.urc_abnormal_cqe_type = 2'b10;
    aeqe.packet_opcode = 8'h81;
    aeqe.ecode = 8'h5a;
    aeqe.qpn = 18'h2aaaa;
    aeqe.urc_remote_ecode = 8'he1;
    aeqe.wqe_wrap = 1'b1;
    aeqe.wqe_index = 23'h654321;
    s = aeqe.set_profile_owner_authority(
      RDMA_AEQE_EVENT_QP, RDMA_RESOURCE_QP);
    ok("aeqe qp canonical authority", s);
    s = c.encode(aeqe, im);
    ok("aeqe encode", s);
    s = c.decode(im, eq_model);
    ok("aeqe decode", s);
    if (s == null || !s.ok() || !$cast(aeqe_decoded, eq_model) ||
        aeqe_decoded.valid !== aeqe.valid ||
        aeqe_decoded.qp_state !== aeqe.qp_state ||
        aeqe_decoded.urc_flag !== aeqe.urc_flag ||
        aeqe_decoded.urc_abnormal_cqe_type !== aeqe.urc_abnormal_cqe_type ||
        aeqe_decoded.packet_opcode !== aeqe.packet_opcode ||
        aeqe_decoded.ecode !== aeqe.ecode ||
        aeqe_decoded.qpn !== aeqe.qpn ||
        aeqe_decoded.urc_remote_ecode !== aeqe.urc_remote_ecode ||
        aeqe_decoded.wqe_wrap !== aeqe.wqe_wrap ||
        aeqe_decoded.wqe_index !== aeqe.wqe_index)
      `uvm_error("AEQE_ROUNDTRIP", "QP-owned AEQE fields did not round-trip")

    aeqe_copy = rdma_hw_aeqe_model::type_id::create("aeqe_copy");
    aeqe_copy.copy(aeqe);
    if (aeqe_copy.urc_flag !== aeqe.urc_flag ||
        aeqe_copy.urc_remote_ecode !== aeqe.urc_remote_ecode ||
        aeqe_copy.wqe_index !== aeqe.wqe_index ||
        aeqe_copy.qpn !== aeqe.qpn)
      `uvm_error("AEQE_COPY", "AEQE detached copy lost fields")

    // logical_cqn_eqn 的上界覆盖 13-bit high 与 6-bit low 的拼接边界，
    // 防止实现把 low 当成 high 的低位截断或错误左移；该纯计算
    // 检查后立即清零 split ID，不让它进入后续 QP canonical image。
    aeqe.cqn_eqn_high = 13'h1fff;
    aeqe.cqn_eqn_low = 6'h3f;
    if (aeqe.logical_cqn_eqn() !== 19'h7ffff)
      `uvm_error("AEQE_CQN_EQN_BOUNDARY", "AEQE CQN/EQN upper boundary is wrong")
    aeqe.cqn_eqn_high = '0;
    aeqe.cqn_eqn_low = '0;

    // QP non-URC 事件不拥有 abnormal subtype/remote/index；改变
    // selector 后的同一 typed payload 必须被拒绝，不能由 encoder 静默清零。
    aeqe.urc_flag = 1'b0;
    s = c.encode(aeqe, im);
    if (s == null || s.ok())
      `uvm_error("AEQE_URC_INACTIVE_OVERLAY",
                 "AEQE accepted inactive URC fields with QP authority")
    aeqe.urc_abnormal_cqe_type = '0;
    aeqe.packet_opcode = '0;
    aeqe.urc_remote_ecode = '0;
    aeqe.wqe_wrap = 1'b0;
    aeqe.wqe_index = '0;
    s = c.encode(aeqe, im);
    ok("aeqe qp non-urc canonical baseline", s);

    // canonical 新建事件只能 author 驱动 qp.h 定义的 0..5；raw literal 的
    // 6/7 已在独立 decode/replay 用例证明可保留，两条 authority 不能混用。
    aeqe.qp_state = 3'd6;
    expect_aeqe_encode_rejected("AEQE_CANONICAL_QP_STATE_6", c, aeqe);
    aeqe.qp_state = 3'd7;
    expect_aeqe_encode_rejected("AEQE_CANONICAL_QP_STATE_7", c, aeqe);
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

    sq = rdma_hw_sqe_model::type_id::create("sq");
    sq.transport = RDMA_TRANSPORT_RC;
    sq.qp_h = h("q", RDMA_RESOURCE_QP, 'h15555);
    sq.hw_opcode = 4'hd;
    sq.icos = 5;
    sq.qp_sn = 8'ha6;
    sq.dst_port = 11;
    sq.index = 'h4567;
    sq.wrap = 1;
    sq.sign_en = 1;
    sq.se = 1;
    sq.fence = 2;
    sq.ce = 2;
    sq.valid = 1;
    sq.signature = 8'hc7;

    re = rdma_sqe_rc_ext::type_id::create("re");
    re.remote_access_valid = 1;
    re.rkey_valid = 1;
    re.rkey = 32'hdeadbeef;
    re.remote_addr.value = 64'h0123456789abcdef;
    sq.transport_ext = re;

    sg = rdma_sge::type_id::create("sg");
    sg.iova.value = 64'h1000;
    sg.length = 8;
    sq.sges.push_back(sg);
    sq.sge_num = 1;

    s = r.lookup(
        '{hw_version:"rdma", image_kind:RDMA_IMAGE_SQE,
          object_type:"sqe", variant:"rc", opcode:0}, c);
    ok("lookup sq", s);
    s = c.encode(sq, im);
    ok("sq encode", s);
    s = c.decode(im, m);
    ok("sq decode", s);
    $cast(sq2, m);
    s = c.encode(sq2, im2);
    ok("sq reencode", s);
    eq_bytes("sq roundtrip", im, im2);

    // F2 RED：该 fixture 只有一个 8-byte literal SGE，合法模型和 wire
    // SGE_NUM 均必须为 1；恢复旧的 caller 值 4 时必须失败且不发布 image。
    if (im == null || im.bytes[17] !== 8'd1)
      `uvm_error("SQE_SGE_NUM_QUEUE_POSITIVE",
                 "single-SGE queue fixture did not publish count one")
    sq.sge_num = 8'd4;
    s = c.encode(sq, im);
    if (s == null || s.ok() || im != null)
      `uvm_error("SQE_SGE_NUM_QUEUE_MISMATCH",
                 "queue codec accepted caller sge_num four for one SGE")
    sq.sge_num = 8'd1;
    s = c.encode(sq, im);
    ok("sq restore canonical sge_num", s);

    // RED：驱动 wr.c 固定 SQE SIGN_EN(bit56)=1；raw bit 为零的镜像即使
    // 重新计算 signature 也必须被 codec 拒绝，不能由 decode 强行改写为 1。
    rqe_builder = new("sqe_sign_en_red_builder");
    s = rqe_builder.deserialize(im.bytes);
    ok("sqe sign-en red deserialize", s);
    s = rqe_builder.put_field(0, 56, 1, 1'b0);
    ok("sqe sign-en red mutate", s);
    s = rqe_builder.serialize(rqe_bytes);
    ok("sqe sign-en red serialize", s);
    foreach (im.bytes[i]) im.bytes[i] = rqe_bytes[i];
    no_sgb.delete();
    expected_rqe_signature = ~rdma_hw_sq_signature_xor(im, no_sgb);
    s = rqe_builder.put_field(16, 56, 8, expected_rqe_signature);
    ok("sqe sign-en red signature", s);
    s = rqe_builder.serialize(rqe_bytes);
    ok("sqe sign-en red signature serialize", s);
    foreach (im.bytes[i]) im.bytes[i] = rqe_bytes[i];
    m = null;
    s = c.decode(im, m);
    if (s == null || s.ok() || m != null)
      `uvm_error("SQE_SIGN_EN_FIXED", "raw SQE SIGN_EN=0 was accepted")

    // RED：驱动硬件 opcode 表只允许已知 4-bit opcode；未知 raw 值不能
    // default 成 SEND，否则会把不可识别的 WQE 当作合法业务请求。
    s = c.encode(sq, im);
    ok("sqe unknown opcode baseline", s);
    rqe_builder = new("sqe_unknown_opcode_red_builder");
    s = rqe_builder.deserialize(im.bytes);
    ok("sqe unknown opcode deserialize", s);
    s = rqe_builder.put_field(0, 32, 4, 4'hf);
    ok("sqe unknown opcode mutate", s);
    s = rqe_builder.serialize(rqe_bytes);
    ok("sqe unknown opcode serialize", s);
    foreach (im.bytes[i]) im.bytes[i] = rqe_bytes[i];
    expected_rqe_signature = ~rdma_hw_sq_signature_xor(im, no_sgb);
    s = rqe_builder.put_field(16, 56, 8, expected_rqe_signature);
    ok("sqe unknown opcode signature", s);
    s = rqe_builder.serialize(rqe_bytes);
    ok("sqe unknown opcode signature serialize", s);
    foreach (im.bytes[i]) im.bytes[i] = rqe_bytes[i];
    m = null;
    s = c.decode(im, m);
    if (s == null || s.ok() || m != null)
      `uvm_error("SQE_UNKNOWN_OPCODE", "unknown raw SQE opcode was accepted")

    // RED：驱动 wr.c 在 num_sge=0 或所有 SGE 长度均为零时仍发布合法
    // RC SEND WQE；模型不能把“无 payload”误判为缺少 payload shape。
    sq_empty = rdma_hw_sqe_model::type_id::create("sq_empty_payload");
    sq_empty.transport = RDMA_TRANSPORT_RC;
    sq_empty.qp_h = h("sq_empty_qp", RDMA_RESOURCE_QP, 'h15556);
    sq_empty.opcode = RDMA_WR_SEND;
    sq_empty.hw_opcode = RDMA_SQ_OPCODE_SEND;
    sq_empty.valid = 1'b1;
    sq_empty.transport_ext = rdma_sqe_rc_ext::type_id::create("sq_empty_ext");
    s = c.encode(sq_empty, im);
    if (s == null || !s.ok())
      `uvm_error("SQE_ZERO_PAYLOAD",
                 $sformatf("zero-payload SEND was rejected: %s",
                           s == null ? "<null>" : s.message))
    else begin
      s = c.decode(im, m);
      if (s == null || !s.ok())
        `uvm_error("SQE_ZERO_PAYLOAD_DECODE",
                   "zero-payload SEND image did not decode")
    end

    sq_empty.sges.push_back(rdma_sge::type_id::create("sq_zero_length_sge"));
    sq_empty.sges[0].length = 0;
    s = c.encode(sq_empty, im);
    if (s == null || !s.ok())
      `uvm_error("SQE_ZERO_LENGTH_SGE",
                 $sformatf("all-zero-length SEND was rejected: %s",
                           s == null ? "<null>" : s.message))

    // Even when a caller carried forward an explicit direct-SGE mode, wr.c
    // filters the zero-length entry before choosing the wire mode.  Verify
    // this stale-mode case follows the same driver ABI as inferred mode.
    sq_empty.payload_mode = RDMA_SQ_PAYLOAD_SGE_WQE;
    s = c.encode(sq_empty, im);
    if (s == null || !s.ok())
      `uvm_error("SQE_ZERO_LENGTH_EXPLICIT_MODE",
                 $sformatf("explicit SGE mode rejected empty SEND: %s",
                           s == null ? "<null>" : s.message))

    // 语义模型校验：rdma_hw_sqe_model 覆盖 validate 时仍必须保留基类的
    // opcode/SGE 约束。驱动允许 SEND 的零 payload，但 RDMA READ 仍要求
    // 至少一个非零长度目标 SGE，atomic 仍要求单个 8-byte 本地 SGE。
    s = sq_empty.validate();
    if (s == null || !s.ok())
      `uvm_error("SQE_MODEL_ZERO_PAYLOAD",
                 $sformatf("semantic SEND validation rejected zero payload: %s",
                           s == null ? "<null>" : s.message))

    sq_empty.opcode = RDMA_WR_RDMA_READ;
    s = sq_empty.validate();
    if (s == null || s.ok())
      `uvm_error("SQE_MODEL_READ_NO_SGE",
                 "semantic RDMA READ validation accepted an empty SGE list")

    sq_empty.opcode = RDMA_WR_ATOMIC_CMP_SWAP;
    s = sq_empty.validate();
    if (s == null || s.ok())
      `uvm_error("SQE_MODEL_ATOMIC_NO_SGE",
                 "semantic atomic validation accepted an empty SGE list")

    rq = rdma_hw_rqe_model::type_id::create("rq");
    rq.target_h = h("rq", RDMA_RESOURCE_QP, 1);
    rq.qpn = 'habcde;
    rq.qp_sn = 'h5a;
    rq.hw_opcode = 9;
    rq.index = 'h3456;
    rq.wrap = 1;
    rq.valid = 1;
    rq.payload_len = 32'd24;
    rq.signature = 8'h96;
    // >2 valid SGEs selects the driver's external SGB mode.  Keep this
    // fixture aligned with wr.c: the detached SGB descriptor count and TPL
    // must describe all three non-zero SGEs, even though the codec only emits
    // their address into the 64-byte RQE image.
    rq.sge_num = 3;
    rq.sges.push_back(sg);
    rq_sg2 = rdma_sge::type_id::create("rq_external_sg2");
    rq_sg2.length = 32'd8;
    rq_sg2.lkey = 32'h2233_4455;
    rq_sg2.iova.value = 64'h0000_0000_0000_2000;
    rq.sges.push_back(rq_sg2);
    rq_sg3 = rdma_sge::type_id::create("rq_external_sg3");
    rq_sg3.length = 32'd8;
    rq_sg3.lkey = 32'h6677_8899;
    rq_sg3.iova.value = 64'h0000_0000_0000_3000;
    rq.sges.push_back(rq_sg3);
    s = r.lookup(
        '{hw_version:"rdma", image_kind:RDMA_IMAGE_RQE,
          object_type:"rqe", variant:"default", opcode:0},
        c
      );
    ok("lookup rq", s);

    // RED：wr.c 的 xtrdma_set_rq_wqe_sge_info() 统计有效 SGE 数后，只有
    // 统计值大于 2 才进入 external SGB；发布到 qword2 的 SGE_NUM 也正是
    // 这个统计值。模型若声明 SGE_NUM=3 却只给一个有效 SGE，不能生成
    // 驱动永远不会产生的 raw image。
    rq_external_mismatch = rdma_hw_rqe_model::type_id::create(
        "rq_external_count_mismatch");
    rq_external_mismatch.target_h = h(
        "rq_external_count_mismatch_qp", RDMA_RESOURCE_QP, 11);
    rq_external_mismatch.qpn = 24'h010203;
    rq_external_mismatch.qp_sn = 8'h04;
    rq_external_mismatch.hw_opcode = 4'h9;
    rq_external_mismatch.index = 15'h0011;
    rq_external_mismatch.valid = 1'b1;
    rq_external_mismatch.sge_num = 8'd3;
    rq_external_mismatch.payload_len = 32'd8;
    s = rq_external_mismatch.set_sgb_pa_encoded(55'h123);
    ok("rq external mismatch sgb", s);
    rq_external_sg1 = rdma_sge::type_id::create("rq_external_mismatch_sg");
    rq_external_sg1.length = 32'd8;
    rq_external_sg1.lkey = 32'h0102_0304;
    rq_external_sg1.iova.value = 64'h0000_0000_0000_1000;
    rq_external_mismatch.sges.push_back(rq_external_sg1);
    s = c.encode(rq_external_mismatch, im);
    if (s == null || s.ok())
      `uvm_error("RQE_EXTERNAL_COUNT",
                 "external RQE accepted SGE_NUM that disagrees with valid SGE count")

    // RED：wr.c/queue data 路径最多只为 32 个有效 SGE 分配 external SGB
    // descriptor；RQE codec 对 33 个非零 SGE 必须 fail-closed，不能把超出
    // 驱动上限的 SGE_NUM 发布到 qword2 或 image_check 中。
    rq_count_overflow = rdma_hw_rqe_model::type_id::create(
        "rq_valid_sge_count_overflow");
    rq_count_overflow.target_h = h(
        "rq_valid_sge_count_overflow_qp", RDMA_RESOURCE_QP, 14);
    rq_count_overflow.qpn = 24'h010206;
    rq_count_overflow.qp_sn = 8'h07;
    rq_count_overflow.hw_opcode = 4'h9;
    rq_count_overflow.index = 15'h0014;
    rq_count_overflow.valid = 1'b1;
    rq_count_overflow.sge_num = 8'd33;
    rq_count_overflow.payload_len = 32'd33;
    s = rq_count_overflow.set_sgb_pa_encoded(55'h124);
    ok("rq count overflow sgb", s);
    for (int unsigned count_i = 0; count_i < 33; count_i++) begin
      rdma_sge count_sg;

      count_sg = rdma_sge::type_id::create(
          $sformatf("rq_count_overflow_sg_%0d", count_i));
      count_sg.length = 32'd1;
      count_sg.lkey = count_i;
      count_sg.iova.value = 64'h0000_0000_0010_0000 + count_i;
      rq_count_overflow.sges.push_back(count_sg);
    end
    s = c.encode(rq_count_overflow, im);
    if (s == null || s.ok())
      `uvm_error("RQE_SGE_COUNT_LIMIT",
                 "RQE accepted more than the driver's 32 valid SGE limit")

    // RED：即使 raw image 伪造 qword2.SGE_NUM=33，image_check 也必须在
    // external 布局判定前拒绝该驱动不可消费的计数，且 detached decode 不得
    // 发布半成品模型。
    // 伪造 raw image 前先把基准 fixture 置为合法 external SGB；否则
    // encode 会因缺少 sgb_pa 提前失败，无法构造待变异的 64B image。
    s = rq.set_sgb_pa_encoded(55'h124);
    ok("rq image-check baseline sgb", s);
    s = c.encode(rq, im);
    ok("rq image-check baseline encode", s);
    rqe_builder = new("rq_count_overflow_image_builder");
    s = rqe_builder.deserialize(im.bytes);
    ok("rq count overflow image deserialize", s);
    s = rqe_builder.put_field(16, 48, 8, 8'd33);
    ok("rq count overflow image count", s);
    s = rqe_builder.serialize(rqe_bytes);
    ok("rq count overflow image serialize", s);
    foreach (im.bytes[i])
      im.bytes[i] = rqe_bytes[i];
    m = null;
    s = c.decode(im, m);
    if (s == null || s.ok() || m != null)
      `uvm_error("RQE_IMAGE_SGE_COUNT_LIMIT",
                 "RQE image_check accepted SGE_NUM above 32")

    // RED：wr.c 累加每个有效 SGE 的 length，并把该和写入 TPL；调用方
    // 提供的 payload_len 不能覆盖真实驱动计算结果。该 fixture 的一条
    // SGE 长度为 8、TPL 却为 9，编码必须 fail-closed。
    rq_payload_mismatch = rdma_hw_rqe_model::type_id::create(
        "rq_payload_length_mismatch");
    rq_payload_mismatch.target_h = h(
        "rq_payload_length_mismatch_qp", RDMA_RESOURCE_QP, 12);
    rq_payload_mismatch.qpn = 24'h010204;
    rq_payload_mismatch.qp_sn = 8'h05;
    rq_payload_mismatch.hw_opcode = 4'h9;
    rq_payload_mismatch.index = 15'h0012;
    rq_payload_mismatch.valid = 1'b1;
    rq_payload_mismatch.sge_num = 8'd1;
    rq_payload_mismatch.payload_len = 32'd9;
    rq_external_sg2 = rdma_sge::type_id::create("rq_payload_mismatch_sg");
    rq_external_sg2.length = 32'd8;
    rq_external_sg2.lkey = 32'h0506_0708;
    rq_external_sg2.iova.value = 64'h0000_0000_0000_2000;
    rq_payload_mismatch.sges.push_back(rq_external_sg2);
    s = c.encode(rq_payload_mismatch, im);
    if (s == null || s.ok())
      `uvm_error("RQE_TPL_SUM",
                 "RQE accepted payload_len that disagrees with SGE length sum")

    // RED：wr.h 定义 SGE length[30:0] 的 wire zero 为 2 GiB sentinel；
    // 驱动不会额外检查 lkey 或 VA 是否非零。因此全零 descriptor 仍是
    // 合法的 2-GiB SGE，codec 不应凭空增加“身份字段必须非零”的限制。
    rq_zero_sentinel = rdma_hw_rqe_model::type_id::create(
        "rq_zero_length_sentinel");
    rq_zero_sentinel.target_h = h(
        "rq_zero_length_sentinel_qp", RDMA_RESOURCE_QP, 13);
    rq_zero_sentinel.qpn = 24'h010205;
    rq_zero_sentinel.qp_sn = 8'h06;
    rq_zero_sentinel.hw_opcode = 4'h9;
    rq_zero_sentinel.index = 15'h0013;
    rq_zero_sentinel.valid = 1'b1;
    rq_zero_sentinel.sge_num = 8'd1;
    rq_zero_sentinel.payload_len = 32'h8000_0000;
    rq_zero_sentinel_sg = rdma_sge::type_id::create(
        "rq_zero_length_sentinel_sg");
    rq_zero_sentinel_sg.length = 32'h8000_0000;
    rq_zero_sentinel_sg.lkey = 32'h0;
    rq_zero_sentinel_sg.iova.value = 64'h0;
    rq_zero_sentinel.sges.push_back(rq_zero_sentinel_sg);
    s = c.encode(rq_zero_sentinel, im);
    if (s == null || !s.ok())
      `uvm_error("RQE_ZERO_SENTINEL",
                 $sformatf("2-GiB zero descriptor was rejected: %s",
                           s == null ? "<null>" : s.message))
    else begin
      s = c.decode(im, m);
      if (s == null || !s.ok() || !$cast(rq2, m) ||
          rq2.sges.size() != 1 ||
          rq2.sges[0].length !== 32'h8000_0000 ||
          rq2.sges[0].lkey !== 32'h0 ||
          rq2.sges[0].iova.value !== 64'h0)
        `uvm_error("RQE_ZERO_SENTINEL",
                   "2-GiB zero descriptor did not round-trip through raw image")
    end

    // RED：wr.c 在 external SGB 路径上无条件把 SIGN_EN(bit56) 置一，
    // 即使 QP 的 rq_sign_en 没有单独打开；RQE codec 必须把这个驱动强制的
    // header 位编码出来，而不能只发布 SGB_PA。该断言直接检查 64B wire
    // image，避免用模型中尚不存在的字段掩盖 ABI 缺口。
    s = rq.set_sgb_pa_encoded(55'h1234_5678_9abc_de);
    ok("rq external sign fixture sgb", s);
    s = c.encode(rq, im);
    ok("rq external sign encode", s);
    if (s != null && s.ok() && im != null) begin
      rqe_builder = new("rqe_external_sign_builder");
      s = rqe_builder.deserialize(im.bytes);
      ok("rq external sign deserialize", s);
      rqe_builder.get_words(rqe_words);
      if (rqe_words.size() != 8 || rqe_words[0][56] !== 1'b1)
        `uvm_error("RQE_SIGN_EN_ENCODE",
                   "external SGB RQE did not set driver SIGN_EN bit56")

      // 构造同一份驱动会发布的 raw image，要求 decode 接受 bit56 并在
      // 后续 Green 阶段把它映射到 detached RQE model，而不是当 reserved。
      s = rqe_builder.put_field(0, 56, 1, 1'b1);
      ok("rq external sign raw bit", s);
      s = rqe_builder.serialize(rqe_bytes);
      ok("rq external sign raw serialize", s);
      foreach (im.bytes[i])
        im.bytes[i] = rqe_bytes[i];
      m = null;
      s = c.decode(im, m);
      if (s == null || s.ok() || m != null)
        `uvm_error("RQE_SIGN_EN_DECODE",
                   "external RQE was decoded without descriptor authority")
    end

    // RED：wr.c:808-825 的 RQE 签名覆盖 header、WQE byte8..63 和
    // external-SGB 中实际写入的 descriptor 字节（SGE_NUM * 16），而不是
    // 只覆盖 64B WQE。当前 codec 仍直接采用调用方 signature 字段，故该
    // 断言应在实现修复前失败。
    rqe_descriptor_bytes.delete();
    foreach (rq.sges[i]) begin
      bit [31:0] descriptor_length;
      descriptor_length = rq.sges[i].length == 32'h8000_0000 ?
                          32'b0 : rq.sges[i].length;
      for (int unsigned j = 0; j < 4; j++)
        rqe_descriptor_bytes.push_back(
            descriptor_length[31 - j * 8 -: 8]);
      for (int unsigned j = 0; j < 4; j++)
        rqe_descriptor_bytes.push_back(
            rq.sges[i].lkey[31 - j * 8 -: 8]);
      for (int unsigned j = 0; j < 8; j++)
        rqe_descriptor_bytes.push_back(
            rq.sges[i].iova.value[63 - j * 8 -: 8]);
    end
    expected_rqe_signature = ~rdma_hw_sq_signature_xor(im,
                                                        rqe_descriptor_bytes);
    if (im == null || im.bytes[16] !== expected_rqe_signature)
      `uvm_error("RQE_SGB_SIGNATURE",
                 $sformatf("external RQE signature mismatch actual=0x%02x expected=0x%02x",
                           im == null ? 0 : im.bytes[16],
                           expected_rqe_signature))

    // RED：raw decode 只有 64B WQE 和 SGB_PA，没有 host-memory descriptor
    // authority；plain decode 必须 fail-closed，不能把不存在的 descriptor
    // 当成零填充。调用方拿到真实 descriptor authority 后，必须走 RQE 专用
    // overload，验证完整 wr.c signature 并把 authority 固定到 detached model。
    s = c.decode(im, m);
    if (s == null || s.ok() || m != null)
      `uvm_error("RQE_SGB_AUTHORITY",
                 "external RQE decoded without descriptor authority")
    if (!$cast(rqe_codec, c)) begin
      `uvm_error("RQE_SGB_AUTHORITY", "RQE registry codec type mismatch")
    end
    else begin
      s = rqe_codec.decode_with_sgb_descriptor_bytes(
          im, rqe_descriptor_bytes, m);
      ok("rq external descriptor authority decode", s);
      if (s == null || !s.ok() || !$cast(rq2, m) ||
          !rq2.external_sgb_descriptor_authority_valid)
        `uvm_error("RQE_SGB_AUTHORITY",
                   "explicit descriptor authority did not permit decode")
      else begin
        s = c.encode(rq2, im2);
        if (s == null || !s.ok())
          `uvm_error("RQE_SGB_AUTHORITY",
                     $sformatf("explicit descriptor authority did not permit re-encode: %s",
                               s == null ? "<null>" : s.message))
        else
          eq_bytes("rq external descriptor round-trip", im, im2);
      end

      // fresh model 没有 codec decode-active capability；即使拿到同一个 idle
      // codec handle，也不能直接建立 raw provenance 或注入 detached descriptors。
      rq_fresh_raw = rdma_hw_rqe_model::type_id::create(
          "rq_fresh_raw_provenance");
      s = rq_fresh_raw.mark_decoded_raw_sgb_provenance(rqe_codec);
      if (s == null || s.ok())
        `uvm_error("RQE_FRESH_RAW_PROVENANCE",
                   "fresh model forged raw provenance outside decode")

      // typed model 即使携带 external descriptor bytes，也必须与 detached
      // SGE 的 count、payload 和每个 descriptor 完全一致；不能靠公开 authority
      // 字段绕过 canonical typed source。
      rq_forged_external = rdma_hw_rqe_model::type_id::create(
          "rq_forged_typed_external");
      rq_forged_external.copy(rq);
      forged_rqe_descriptor_bytes.delete();
      foreach (rqe_descriptor_bytes[i])
        forged_rqe_descriptor_bytes.push_back(rqe_descriptor_bytes[i]);
      forged_rqe_descriptor_bytes[0] ^= 8'h01;
      s = rq_forged_external.set_external_sgb_descriptor_bytes(
          forged_rqe_descriptor_bytes);
      if (s == null || s.ok())
        `uvm_error("RQE_TYPED_EXTERNAL_AUTHORITY",
                   "typed RQE accepted descriptor bytes that disagree with SGE");
      s = rq_forged_external.set_external_sgb_descriptor_bytes(
          rqe_descriptor_bytes);
      ok("rq typed external authority install", s);
      if (s != null && s.ok()) begin
        rq_forged_external.sges[0].lkey ^= 32'h1;
        s = c.encode(rq_forged_external, im2);
        if (s == null || s.ok())
          `uvm_error("RQE_TYPED_EXTERNAL_MUTATION",
                     "typed SGE mutation bypassed frozen external authority")
      end

      // raw decode 的 provenance、count/payload snapshot 和 descriptor snapshot
      // 必须共同生效；任一 public wire/descriptor mutation 都要求先 clear 后重授权。
      if (!rq2.has_decoded_raw_sgb_provenance())
        `uvm_error("RQE_RAW_PROVENANCE",
                   "external raw decode did not retain detached provenance")
      rq2.sge_num = 8'd4;
      s = c.encode(rq2, im2);
      if (s == null || s.ok())
        `uvm_error("RQE_RAW_COUNT_MUTATION",
                   "raw authority accepted mutated SGE_NUM")
      rq2.sge_num = 8'd3;
      rq2.payload_len = 32'd25;
      s = c.encode(rq2, im2);
      if (s == null || s.ok())
        `uvm_error("RQE_RAW_PAYLOAD_MUTATION",
                   "raw authority accepted mutated payload length")
      rq2.payload_len = 32'd24;
      rq2.external_sgb_descriptor_bytes[0] ^= 8'h01;
      s = c.encode(rq2, im2);
      if (s == null || s.ok())
        `uvm_error("RQE_RAW_DESCRIPTOR_MUTATION",
                   "raw authority accepted mutated descriptor bytes")
      rq2.external_sgb_descriptor_bytes[0] = rqe_descriptor_bytes[0];
      rq2.clear_external_sgb_descriptor_authority();
      s = c.encode(rq2, im2);
      if (s == null || s.ok())
        `uvm_error("RQE_RAW_CLEAR_REAUTHORIZE",
                   "cleared raw descriptor authority unexpectedly encoded")
      s = rq2.set_external_sgb_descriptor_bytes(rqe_descriptor_bytes);
      ok("rq raw descriptor re-authorize", s);
      if (s != null && s.ok()) begin
        s = c.encode(rq2, im2);
        ok("rq raw descriptor re-authorized encode", s);
      end
      rq2.sge_num = 8'd33;
      s = rq2.set_external_sgb_descriptor_bytes(rqe_descriptor_bytes);
      if (s == null || s.ok())
        `uvm_error("RQE_RAW_COUNT_LIMIT",
                   "raw authority setter accepted more than 32 descriptors")
      rq2.sge_num = 8'd3;
      short_rqe_descriptor_bytes.delete();
      for (int unsigned short_i = 0; short_i < 16; short_i++)
        short_rqe_descriptor_bytes.push_back(8'h00);
      s = rq2.set_external_sgb_descriptor_bytes(short_rqe_descriptor_bytes);
      if (s == null || s.ok())
        `uvm_error("RQE_RAW_DESCRIPTOR_LENGTH",
                   "raw authority setter accepted a truncated descriptor array")
    end

    // RED：驱动 wr.c 的 SGE wire 长度只有低 31 位，bit31 是 reserved；
    // 在线语义中 length=2GiB(0x8000_0000) 必须编码为零，解码再还原为
    // 2GiB。先锁定普通 31-bit 最大值，再锁定 zero↔2GiB 特殊映射。
    rq_length = rdma_hw_rqe_model::type_id::create("rq_length");
    rq_length.target_h = h("rq_length", RDMA_RESOURCE_QP, 4);
    rq_length.qpn = 24'h345678;
    rq_length.qp_sn = 8'h2c;
    rq_length.hw_opcode = 4'h9;
    rq_length.index = 15'h0042;
    rq_length.valid = 1'b1;
    rq_length.sge_num = 8'd1;
    rq_length_sg = rdma_sge::type_id::create("rq_length_sg");
    rq_length_sg.lkey = 32'h5566_7788;
    rq_length_sg.iova.value = 64'h0123_4567_89ab_cdef;
    rq_length.sges.push_back(rq_length_sg);

    rq_length_sg.length = 32'h7fff_ffff;
    rq_length.payload_len = 32'h7fff_ffff;
    s = c.encode(rq_length, im);
    ok("rq 31-bit maximum encode", s);
    if (s != null && s.ok()) begin
      rqe_builder = new("rqe_31bit_length_builder");
      s = rqe_builder.deserialize(im.bytes);
      ok("rq 31-bit maximum deserialize", s);
      rqe_builder.get_words(rqe_words);
      if (rqe_words.size() != 8 ||
          rqe_words[4][62:32] !== 31'h7fff_ffff)
        `uvm_error("RQE_SGE_LEN_31BIT",
                   "31-bit SGE length was not placed at qword4[62:32]")
      s = c.decode(im, m);
      ok("rq 31-bit maximum decode", s);
      if (s == null || !s.ok() || !$cast(rq_inline_decoded, m) ||
          rq_inline_decoded.sges.size() != 1 ||
          rq_inline_decoded.sges[0].length !== 32'h7fff_ffff)
        `uvm_error("RQE_SGE_LEN_31BIT",
                   "31-bit SGE length did not round-trip")

      // RED：wr.h/wr.c 固定 RQE hardware opcode 为 4'h9。保持其余
      // qword 与签名不变，raw validate/decode 必须拒绝伪造的 4'h8，
      // 不能把调用方可写的 opcode 发布成合法 receive WQE。
      rq_bad_opcode_image = rdma_hw_image::type_id::create(
          "rq_bad_opcode_image");
      rq_bad_opcode_image.copy(im);
      rq_bad_opcode_image.bytes[3] =
          (rq_bad_opcode_image.bytes[3] & 8'hf0) | 8'h08;
      m = null;
      s = c.validate_image(rq_bad_opcode_image);
      if (s == null || s.ok())
        `uvm_error("RQE_OPCODE_VALIDATE",
                   "RQE raw validation accepted opcode other than 0x9")
      s = c.decode(rq_bad_opcode_image, m);
      if (s == null || s.ok() || m != null)
        `uvm_error("RQE_OPCODE_DECODE",
                   "RQE raw decode accepted opcode other than 0x9")
    end

    rq_length_sg.length = 32'h8000_0000;
    rq_length.payload_len = 32'h8000_0000;
    s = c.encode(rq_length, im);
    ok("rq 2GiB sentinel encode", s);
    if (s == null || !s.ok()) begin
      `uvm_error("RQE_SGE_LEN_2G",
                 "2GiB SGE length was rejected instead of encoding zero")
    end
    else begin
      rqe_builder = new("rqe_2g_length_builder");
      s = rqe_builder.deserialize(im.bytes);
      ok("rq 2GiB sentinel deserialize", s);
      rqe_builder.get_words(rqe_words);
      if (rqe_words.size() != 8 || rqe_words[4][62:32] !== 31'b0 ||
          rqe_words[4][63] !== 1'b0)
        `uvm_error("RQE_SGE_LEN_2G",
                   "2GiB SGE length was not encoded as a zero 31-bit wire value")
      s = c.decode(im, m);
      ok("rq 2GiB sentinel decode", s);
      if (s == null || !s.ok() || !$cast(rq_inline_decoded, m) ||
          rq_inline_decoded.sges.size() != 1 ||
          rq_inline_decoded.sges[0].length !== 32'h8000_0000)
        `uvm_error("RQE_SGE_LEN_2G",
                   "zero wire SGE length was not restored to 2GiB")
    end

    // RED：驱动 wr.c 在计算有效 SGE 数量时跳过 length==0 的条目，随后
    // 把后面的有效 SGE 左移填入 inline RQE。模型和 codec 必须保留这一
    // 过滤语义，而不能把零长度条目当成硬件 SGE 或直接拒绝整个 WQE。
    rq_zero_filtered = rdma_hw_rqe_model::type_id::create(
        "rq_zero_filtered");
    rq_zero_filtered.target_h = h(
        "rq_zero_filtered", RDMA_RESOURCE_QP, 3);
    rq_zero_filtered.qpn = 24'h234567;
    rq_zero_filtered.qp_sn = 8'h6b;
    rq_zero_filtered.hw_opcode = 4'h9;
    rq_zero_filtered.index = 15'h1234;
    rq_zero_filtered.valid = 1'b1;
    rq_zero_filtered.payload_len = 32'h10;
    rq_zero_filtered.sge_num = 8'd1;

    rq_zero_sg = rdma_sge::type_id::create("rq_zero_sg");
    rq_zero_sg.length = 0;
    rq_zero_sg.lkey = 32'hdead_beef;
    rq_zero_sg.iova.value = 64'h1111_2222_3333_4444;
    rq_zero_valid_sg = rdma_sge::type_id::create("rq_zero_valid_sg");
    rq_zero_valid_sg.length = 32'h10;
    rq_zero_valid_sg.lkey = 32'h1122_3344;
    rq_zero_valid_sg.iova.value = 64'h0123_4567_89ab_cdef;
    rq_zero_filtered.sges.push_back(rq_zero_sg);
    rq_zero_filtered.sges.push_back(rq_zero_valid_sg);

    s = rq_zero_filtered.validate();
    ok("rq zero-length SGE is filtered", s);
    s = c.encode(rq_zero_filtered, im);
    ok("rq zero-length filtered encode", s);
    s = c.decode(im, m);
    ok("rq zero-length filtered decode", s);
    if (s == null || !s.ok() || !$cast(rq_inline_decoded, m) ||
        rq_inline_decoded.sges.size() != 1 ||
        rq_inline_decoded.sges[0].length != rq_zero_valid_sg.length ||
        rq_inline_decoded.sges[0].lkey !== rq_zero_valid_sg.lkey ||
        rq_inline_decoded.sges[0].iova.value !== rq_zero_valid_sg.iova.value)
      `uvm_error("RQE_ZERO_SGE",
                 "zero-length RQE SGE was not filtered before encoding")

    // 驱动允许 num_sge=0：有效 SGE 数为零时选择 inline 空布局，
    // total_payload_len 和 SGE_NUM 均为零，qword4..7 保持全零。
    // 该场景与“列表中包含零长度 SGE”不同，模型必须允许空 sges 队列。
    rq_zero_filtered.sges.delete();
    rq_zero_filtered.sge_num = 8'd0;
    rq_zero_filtered.payload_len = 32'd0;
    rq_zero_filtered.sgb_pa = '0;
    rq_zero_filtered.sign_en = 1'b0;
    s = rq_zero_filtered.validate();
    ok("rq zero-sge validate", s);
    s = c.encode(rq_zero_filtered, im);
    ok("rq zero-sge encode", s);
    s = c.decode(im, m);
    ok("rq zero-sge decode", s);
    if (s == null || !s.ok() || !$cast(rq_inline_decoded, m) ||
        rq_inline_decoded.sges.size() != 0 ||
        rq_inline_decoded.sge_num != 0 ||
        rq_inline_decoded.payload_len != 0 ||
        rq_inline_decoded.sign_en != 0)
      `uvm_error("RQE_ZERO_SGE_EMPTY",
                 "zero-SGE RQE did not round-trip as an empty inline WQE")

    // RED：RQE.SGE_NUM=1 时，驱动只写入第一个 16-byte SGE；第二个槽位
    // qword6/7 必须保持零。保留位检查不能因 inline 模式而放行未声明槽位。
    rq_zero_filtered.sge_num = 8'd1;
    rq_zero_filtered.sges.delete();
    rq_zero_filtered.sges.push_back(rq_zero_valid_sg);
    rq_zero_filtered.payload_len = rq_zero_valid_sg.length;
    s = c.encode(rq_zero_filtered, im);
    ok("rq one-sge inline encode", s);
    rqe_builder = new("rqe_unused_inline_slot_builder");
    s = rqe_builder.deserialize(im.bytes);
    ok("rq unused inline slot deserialize", s);
    s = rqe_builder.put_field(48, 0, 1, 1);
    ok("rq unused inline slot mutation", s);
    s = rqe_builder.serialize(rqe_bytes);
    ok("rq unused inline slot serialize", s);
    foreach (im.bytes[i]) im.bytes[i] = rqe_bytes[i];
    s = c.decode(im, m);
    if (s == null || s.ok() || m != null)
      `uvm_error("RQE_INLINE_SLOT", "unused inline SGE slot was accepted")

    // RED：驱动 wr.c 在 SGE_NUM=1 时必须把唯一有效 SGE 写入 qword4/qword5。
    // 若四个 payload qword 全为零，该 image 既不是合法 inline RQE，也不是
    // external SGB（qword4 的 SGB_PA=0）；decode 必须拒绝并保持 model=null。
    s = c.encode(rq_zero_filtered, im);
    ok("rq malformed inline baseline encode", s);
    rqe_builder = new("rqe_missing_inline_payload_builder");
    s = rqe_builder.deserialize(im.bytes);
    ok("rq malformed inline baseline deserialize", s);
    for (int unsigned payload_qword = 4;
         payload_qword <= 7;
         payload_qword++) begin
      s = rqe_builder.put_field(payload_qword << 3, 0, 64, 64'b0);
      ok("rq malformed inline zero payload", s);
    end
    s = rqe_builder.serialize(rqe_bytes);
    ok("rq malformed inline serialize", s);
    foreach (im.bytes[i])
      im.bytes[i] = rqe_bytes[i];
    m = null;
    s = c.decode(im, m);
    if (s == null || s.ok() || m != null)
      `uvm_error("RQE_MISSING_INLINE_PAYLOAD",
                 "SGE_NUM=1 with an empty inline payload was accepted")

    // RED：wr.c 的 xtrdma_rq_set_sge() 在 inline RQE 模式下把两个 16-byte
    // SGE 直接写入 WQE byte32/48；qword4/6 的高 32 位是长度、低 32 位是
    // lkey，qword5/7 是完整 VA。当前 codec 只认 qword4 的 SGB_PA，因而
    // 下面的真实驱动布局在修复前会丢失四个 SGE qword。
    rq_inline = rdma_hw_rqe_model::type_id::create("rq_inline");
    rq_inline.target_h = h("rq_inline", RDMA_RESOURCE_QP, 2);
    rq_inline.qpn = 24'h123456;
    rq_inline.qp_sn = 8'h5a;
    rq_inline.hw_opcode = 4'h9;
    rq_inline.index = 15'h3456;
    rq_inline.wrap = 1'b1;
    rq_inline.valid = 1'b1;
    rq_inline.payload_len = 32'h0000_0030;
    rq_inline.signature = 8'h96;
    rq_inline.sge_num = 8'd2;

    rq_sg0 = rdma_sge::type_id::create("rq_inline_sg0");
    rq_sg0.length = 32'h10;
    rq_sg0.lkey = 32'h1122_3344;
    rq_sg0.iova.value = 64'h0123_4567_89ab_cdef;
    rq_inline.sges.push_back(rq_sg0);

    rq_sg1 = rdma_sge::type_id::create("rq_inline_sg1");
    rq_sg1.length = 32'h20;
    rq_sg1.lkey = 32'haabb_ccdd;
    rq_sg1.iova.value = 64'hfedc_ba98_7654_3210;
    rq_inline.sges.push_back(rq_sg1);

    s = c.encode(rq_inline, im);
    ok("rq inline two-sge encode", s);
    if (s == null || !s.ok()) begin
      `uvm_error("RQE_INLINE_SGE", "two-SGE inline RQE was rejected")
    end
    else begin
      rqe_builder = new("rqe_inline_builder");
      s = rqe_builder.deserialize(im.bytes);
      ok("rq inline deserialize", s);
      rqe_builder.get_words(rqe_words);
      if (rqe_words.size() != 8 ||
          rqe_words[4] !== 64'h0000_0010_1122_3344 ||
          rqe_words[5] !== 64'h0123_4567_89ab_cdef ||
          rqe_words[6] !== 64'h0000_0020_aabb_ccdd ||
          rqe_words[7] !== 64'hfedc_ba98_7654_3210)
        `uvm_error("RQE_INLINE_SGE",
                   "inline RQE SGE qwords do not match wr.c layout")

      s = c.decode(im, m);
      ok("rq inline decode", s);
      if (s == null || !s.ok() || !$cast(rq_inline_decoded, m) ||
          rq_inline_decoded.sges.size() != 2 ||
          rq_inline_decoded.sges[0].length != rq_sg0.length ||
          rq_inline_decoded.sges[0].lkey !== rq_sg0.lkey ||
          rq_inline_decoded.sges[0].iova.value !== rq_sg0.iova.value ||
          rq_inline_decoded.sges[1].length != rq_sg1.length ||
          rq_inline_decoded.sges[1].lkey !== rq_sg1.lkey ||
          rq_inline_decoded.sges[1].iova.value !== rq_sg1.iova.value)
        `uvm_error("RQE_INLINE_SGE",
                   "inline RQE decode did not recover both SGEs")
    end

    // RED：驱动 wr.c 对 SIGN_EN=1 的 inline RQE 使用完整 64B WQE（跳过
    // byte16 的 signature）计算 complement-XOR。raw decode 必须验证该
    // 结果；仅提取 signature 字段而接受被篡改的 body 会把损坏的 receive
    // WQE 发布给后续队列逻辑。
    rq_inline.sign_en = 1'b1;
    s = c.encode(rq_inline, im);
    ok("rq inline signed encode", s);
    if (s != null && s.ok()) begin
      rqe_bad_signature_image = rdma_hw_image::type_id::create(
          "rq_inline_bad_signature_image");
      foreach (im.bytes[i])
        rqe_bad_signature_image.bytes.push_back(im.bytes[i]);
      rqe_bad_signature_image.length = im.length;
      rqe_bad_signature_image.alignment = im.alignment;
      rqe_bad_signature_image.endian = im.endian;
      rqe_bad_signature_image.image_kind = im.image_kind;
      rqe_bad_signature_image.hardware_version = im.hardware_version;
      rqe_bad_signature_image.function_generation = im.function_generation;
      rqe_bad_signature_image.write_target_kind = im.write_target_kind;
      rqe_bad_signature_image.backing_target = im.backing_target;
      rqe_bad_signature_image.hmc_target = im.hmc_target;
      rqe_bad_signature_image.bar_target = im.bar_target;
      rqe_bad_signature_image.bytes[16] ^= 8'h01;
      m = null;
      s = c.decode(rqe_bad_signature_image, m);
      if (s == null || s.ok() || m != null)
        `uvm_error("RQE_SIGNATURE_DECODE",
                   "inline RQE with a corrupted signature was accepted")
    end
    rq_inline.sign_en = 1'b0;

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
    s = rqe_codec.decode_with_sgb_descriptor_bytes(
        im, rqe_descriptor_bytes, m);
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
    s = rqe_codec.decode_with_sgb_descriptor_bytes(
        im, rqe_descriptor_bytes, m);
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
    s = rqe_codec.decode_with_sgb_descriptor_bytes(
        im, rqe_descriptor_bytes, m);
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
    // the shared four-state mask helper keeps this rejection unambiguous.
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

    // RED：qword2 bit32 也不属于 SIGNATURE[63:56] 或 SGE_NUM[55:48]。
    // 该位专门覆盖原始 mask 检查的运算符优先级回归；仅检查 bit0
    // 无法证明其余 32 个低位被拒绝。
    s = c.encode(rq, im);
    ok("rq re-encode for qword2 nonzero reserved bit", s);
    rqe_builder = new("rqe_qword2_nonzero_reserved_builder");
    s = rqe_builder.deserialize(im.bytes);
    ok("rqe qword2 nonzero reserved deserialize", s);
    s = rqe_builder.put_field(16, 32, 1, 1);
    ok("rqe qword2 nonzero reserved field", s);
    s = rqe_builder.serialize(rqe_bytes);
    ok("rqe qword2 nonzero reserved serialize", s);
    foreach (im.bytes[i])
      im.bytes[i] = rqe_bytes[i];
    m = null;
    s = c.decode(im, m);
    if (s == null || s.ok() || m != null)
      `uvm_error("RQE_RESERVED_QWORD2",
                 "RQE qword2 bit32 reserved bit was accepted")

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
    // qword0 bit0 is QPN[0] and is therefore a legal driver field.  Use
    // qword2 bit29, one of the [30:28] bits reserved in every CQE overlay,
    // for this negative image so the check remains tied to wr.h rather than
    // an old mask.
    bad = new[64];
    foreach (bad[i])
      bad[i] = 8'h00;
    bad[20] = 8'h20;
    im.bytes.delete();
    foreach (bad[i])
      im.bytes.push_back(bad[i]);
    im.length = 64;
    im.alignment = 64;
    im.endian = RDMA_ENDIAN_BIG;
    im.image_kind = RDMA_IMAGE_CQE;
    im.hardware_version = 1;
    im.function_generation = 1;
    im.write_target_kind = RDMA_HW_TARGET_NONE;
    im.backing_target = '0;
    im.hmc_target = '0;
    im.bar_target = '0;
    s = c.validate_image(im);
    if (s == null || s.ok())
      `uvm_error("reserved", "reserved bits accepted");
    phase.drop_objection(this);
  endtask
endclass
