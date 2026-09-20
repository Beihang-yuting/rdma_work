// 目录/层次：tests/unit/ queue Host-memory submitter 单元测试层。
// 职责：验证 opaque target allocation、SQE 写入回读、CQE/AEQE profile decode、
//   codec null-status fail-closed 与 exactly-once release ledger。
// 依赖：rdma_queue_host_mem_submitter、queue codec registry、mock Host-memory 与 UVM。
// 所有权与生命周期：submitter 私有 ledger 拥有 allocation 记录；mock adapter
//   拥有 backing，测试只持有 opaque target/model 快照并在 run_phase 结束前释放。

// 功能：构造第二次 validate_image 返回 null 的 SQE codec，覆盖 submitter 的 readback codec 边界。
// 输入/输出及副作用：image（输入）；前一次校验沿用真实 RC codec，第二次校验返回 null，不修改 image 或模型。
// 失败/边界：该夹具只用于验证 codec contract violation 被归一化为 CODEC_ERROR；调用方不得发布 image 或继续提交成功路径。
class rdma_null_readback_status_sqe_codec extends rdma_hw_sqe_rc_codec;
  `uvm_object_utils(rdma_null_readback_status_sqe_codec)

  int unsigned validate_calls;

  // 功能：创建 readback null-status codec 并清零校验调用计数。
  // 输入/输出及副作用：name（输入）；new 只建立本地计数，不取得 registry、Host-memory 或 queue 所有权。
  // 失败/边界：计数为零时沿用基类行为；只有第二次 validate_image 注入 null 状态。
  function new(string name = "rdma_null_readback_status_sqe_codec");
    super.new(name);
    validate_calls = 0;
  endfunction

  // 功能：在 SQE 首次写入校验后注入 readback 校验 null 状态，模拟 codec 丢失返回值。
  // 输入/输出及副作用：image（输入）；递增 validate_calls；第一次调用返回真实校验状态，第二次返回 null。
  // 失败/边界：只有恰好第二次调用返回 null；后续调用继续沿用基类，避免掩盖调用次数错误。
  virtual function rdma_status validate_image(rdma_hw_image image);
    validate_calls++;
    if (validate_calls == 2)
      return null;
    return super.validate_image(image);
  endfunction
endclass

// 功能：把一个 hostile SQE codec 注入 registry，同时将其他 image 查询转发到原 registry。
// 输入/输出及副作用：key（输入）、codec（输出）；SQE 查询返回 hostile codec，其他查询保持原 registry 的非拥有引用。
// 失败/边界：hostile codec 为空时返回 INVALID_STATE；非 SQE 查询的错误和输出由 fallback 原样保留。
class rdma_null_readback_status_registry extends rdma_codec_registry;
  `uvm_object_utils(rdma_null_readback_status_registry)

  rdma_codec_registry fallback;
  rdma_codec_base hostile_codec;

  // 功能：创建 hostile registry 并保存 fallback 与注入 codec 的非拥有引用。
  // 输入/输出及副作用：name（输入）；new 初始化引用为空，不复制或接管 codec/registry 生命周期。
  // 失败/边界：引用需由测试在使用前显式设置；未设置时 lookup 返回 INVALID_STATE。
  function new(string name = "rdma_null_readback_status_registry");
    super.new(name);
    fallback = null;
    hostile_codec = null;
  endfunction

  // 功能：按 image kind 选择 hostile SQE codec，验证 submitter 不把 null validate status 当作成功。
  // 输入/输出及副作用：key（输入）、codec（输出）；lookup 只发布非拥有引用，不修改 fallback 内容。
  // 失败/边界：hostile SQE codec 或 fallback 缺失时返回 INVALID_STATE；其他 key
  // 的 fallback null status 由调用方继续 fail closed。
  virtual function rdma_status lookup(
    rdma_codec_key key,
    output rdma_codec_base codec
  );
    codec = null;
    if (key.image_kind == RDMA_IMAGE_SQE &&
        key.object_type == "sqe") begin
      if (hostile_codec == null)
        return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "hostile SQE codec is not configured");
      codec = hostile_codec;
      return rdma_status::success();
    end
    if (fallback == null)
      return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "fallback codec registry is not configured");
    return fallback.lookup(key, codec);
  endfunction
endclass

class rdma_queue_host_mem_submitter_test extends uvm_test;
  `uvm_component_utils(rdma_queue_host_mem_submitter_test)

  // 功能：构造 rdma_queue_host_mem_submitter_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_host_mem_submitter_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_host_mem_submitter_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：function_handle 构造 submitter allocation 使用的固定 Function
  //   authority，提供非零 UID/object_id/generation 供 ledger 身份校验。
  // 输入/输出及副作用：无输入；返回测试拥有的新 rdma_function_handle，
  //   不注册 resource manager，也不把句柄所有权交给 Host-memory adapter。
  // 失败/边界：factory 返回 null 时本 helper 返回 null，随后 request_context
  //   validation 必须 fail closed；固定字段只用于本测试，不代表活动外部 Function。
  function automatic rdma_function_handle function_handle();
    rdma_function_handle result;
    result = rdma_function_handle::type_id::create("function");
    result.function_uid = 64'h1122;
    result.object_id = 7;
    result.generation = 3;
    return result;
  endfunction

  // 功能：request_context 用固定 Function、requester BDF、PASID 与 DMA domain
  //   构造完整 allocation authority，供 opaque target ledger 冻结快照。
  // 输入/输出及副作用：无输入；返回测试拥有的新 context，其中 function_h
  //   来自 function_handle；不分配 backing、不写 Host-memory。
  // 失败/边界：context 或 Function factory 返回 null 时返回的 fixture 不完整，
  //   allocate_target 必须拒绝；本 helper 不回退到默认 BDF/domain 或伪造 route。
  function automatic rdma_dma_request_context request_context();
    rdma_dma_request_context result;
    result = rdma_dma_request_context::type_id::create("request_context");
    result.function_h = function_handle();
    result.requester_bdf = 16'h0102;
    result.pasid_valid = 1'b1;
    result.pasid = 20'h12345;
    result.dma_domain_valid = 1'b1;
    result.dma_domain_id = 9;
    return result;
  endfunction

  // 功能：在 rdma_queue_host_mem_submitter_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    rdma_mock_host_mem mem;
    rdma_codec_registry registry;
    rdma_null_readback_status_registry null_registry;
    rdma_null_readback_status_sqe_codec null_codec;
    rdma_queue_host_mem_submitter submitter;
    rdma_queue_host_mem_target target;
    rdma_dma_request_context request_ctx;
    rdma_status status;
    rdma_hw_sqe_model sqe;
    rdma_sqe_rc_ext rc;
    rdma_sge sge;
    rdma_hw_image image;
    rdma_hw_aeqe_model aeqe;
    rdma_hw_cqe_model cqe_source;
    rdma_hw_cqe_model cqe_decoded;
    rdma_hw_model decoded_model;
    rdma_hw_cqe_codec cqe_codec;
    rdma_codec_base cqe_codec_base;
    int unsigned cqe_sizes[3] = '{32, 64, 128};
    longint unsigned cqe_offsets[3] = '{0, 64, 128};
    byte unsigned aeqe_bytes[16];
    int unsigned release_calls;
    int unsigned release_calls_after;
    rdma_hw_cqe_model ud_source;
    rdma_hw_cqe_model ud_decoded;
    rdma_hw_image ud_image;
    phase.raise_objection(this);

    mem = rdma_mock_host_mem::type_id::create("mem");
    registry = rdma_codec_registry::type_id::create("registry");
    void'(rdma_register_queue_codecs(registry));
    submitter = rdma_queue_host_mem_submitter::type_id::create(
      "submitter");
    submitter.host_mem = mem;
    submitter.registry = registry;
    request_ctx = request_context();

    // The submitter must return an opaque target after validating the
    // injected request context and retaining the allocation privately.
    status = submitter.allocate_target(request_ctx, 256, 64,
                                       RDMA_DMA_BIDIRECTIONAL, target);
    if (status == null || !status.ok() || target == null)
      `uvm_error("ALLOCATE", "queue host-memory target allocation failed")

    sqe = rdma_hw_sqe_model::type_id::create("sqe");
    sqe.transport = RDMA_TRANSPORT_RC;
    sqe.qp_h = rdma_handle::type_id::create("qp");
    sqe.qp_h.kind = RDMA_RESOURCE_QP;
    sqe.qp_h.function_uid = request_ctx.function_h.function_uid;
    sqe.qp_h.generation = request_ctx.function_h.generation;
    sqe.hw_opcode = 0;
    sqe.valid = 1'b1;
    rc = rdma_sqe_rc_ext::type_id::create("rc");
    sqe.transport_ext = rc;
    sge = rdma_sge::type_id::create("sge");
    sge.iova.value = 64'h2000;
    sge.length = 8;
    sqe.sges.push_back(sge);
    sqe.sge_num = 1;
    status = submitter.write_sqe(target, 0, sqe, image);
    if (status == null || !status.ok() || image == null)
      `uvm_error("WRITE", "queue SQE write transaction failed")

    // A codec may return success for the write image and then lose its status
    // while validating the readback image.  The submitter must reject that
    // contract violation without publishing a second image.
    null_registry = rdma_null_readback_status_registry::type_id::create(
      "null_readback_registry"
    );
    null_codec = rdma_null_readback_status_sqe_codec::type_id::create(
      "null_readback_codec"
    );
    null_registry.fallback = registry;
    null_registry.hostile_codec = null_codec;
    submitter.registry = null_registry;
    image = null;
    status = submitter.write_sqe(target, 16, sqe, image);
    if (status == null || status.code != RDMA_SC_CODEC_ERROR || image != null)
      `uvm_error("NULL_READBACK_STATUS",
                 "null codec validation status was accepted or leaked image")
    submitter.registry = registry;

    // Seed a device-produced AEQE in the second slot.  Both CEQE and AEQE
    // are 16 bytes; the submitter must preserve the explicitly selected
    // image kind rather than inferring it from length.
    aeqe_bytes = '{8'hd0, 8'h00, 8'h00, 8'h81, 8'hff, 8'h02, 8'haa,
                   8'haa, 8'h00, 8'he5, 8'h43, 8'h21, 8'h00, 8'h00,
                   8'h00, 8'h00};
    foreach (aeqe_bytes[i])
      mem.regions[0].data[64 + i] = aeqe_bytes[i];
    aeqe = null;
    image = null;
    status = submitter.read_aeqe(target, 64, aeqe, image);
    if (status == null || !status.ok() || aeqe == null || image == null ||
        image.image_kind != RDMA_IMAGE_AEQE)
      `uvm_error("READ_AEQE", "AEQE read selected the wrong 16-byte image kind")

    // CQE reads select the profile per transaction.  Leave the shared
    // registry codec at 64B after producing all three images, then verify
    // 32/64/128B reads still validate and decode without shared-state leaks.
    status = registry.lookup(
      '{hw_version:"rdma", image_kind:RDMA_IMAGE_CQE,
        object_type:"cqe", variant:"default", opcode:8'h00},
      cqe_codec_base);
    if (status == null || !status.ok() || cqe_codec_base == null ||
        !$cast(cqe_codec, cqe_codec_base))
      `uvm_error("CQE_SIZED_CODEC", "CQE codec lookup failed")
    cqe_source = rdma_hw_cqe_model::type_id::create("sized_cqe_source");
    cqe_source.qp_h = sqe.qp_h;
    cqe_source.qpn = 18'h12345;
    cqe_source.wqe_index = 15'h3456;
    cqe_source.wqe_wrap = 1'b1;
    cqe_source.polarity = 1'b1;
    cqe_source.packet_opcode = 8'h04;
    cqe_source.payload_len = 32'h40;
    cqe_source.immediate_data = 32'habcdef01;
    cqe_source.signature = 16'h1234;
    foreach (cqe_sizes[i]) begin
      status = cqe_codec.set_entry_bytes(cqe_sizes[i]);
      if (status == null || !status.ok()) begin
        `uvm_error("CQE_SIZED_ENCODE", $sformatf(
          "CQE profile %0dB setup failed", cqe_sizes[i]))
        continue;
      end
      status = cqe_codec.encode(cqe_source, image);
      if (status == null || !status.ok() || image == null)
        `uvm_error("CQE_SIZED_ENCODE", $sformatf(
          "CQE profile %0dB encode failed", cqe_sizes[i]))
      else foreach (image.bytes[j])
        mem.regions[0].data[cqe_offsets[i] + j] = image.bytes[j];
    end
    void'(cqe_codec.set_entry_bytes(64));
    foreach (cqe_sizes[i]) begin
      decoded_model = null;
      image = null;
      status = submitter.read_cqe_sized(target, cqe_offsets[i], cqe_sizes[i],
                                        cqe_decoded, image);
      if (status == null || !status.ok() || cqe_decoded == null ||
          !$cast(decoded_model, cqe_decoded) || cqe_decoded.qpn != 18'h12345)
        `uvm_error("CQE_SIZED_READ", $sformatf(
          "CQE profile %0dB read/decode failed", cqe_sizes[i]))
    end

    // The UD qword3 overlay is valid driver data, not reserved bytes.  The
    // submitter must therefore expose an explicit per-read variant authority
    // instead of silently decoding every CQE through the shared RC default.
    ud_source = rdma_hw_cqe_model::type_id::create("ud_variant_source");
    ud_source.qp_h = sqe.qp_h;
    ud_source.qpn = 18'h12345;
    ud_source.variant = RDMA_CQE_VARIANT_UD;
    ud_source.rq_cqe = 1'b0;
    ud_source.polarity = 1'b1;
    ud_source.packet_opcode = 8'h04;
    ud_source.payload_len = 0;
    ud_source.ud_src_qpn = 24'h654321;
    ud_source.ud_smac = 48'h1122_3344_5566;
    ud_source.ud_vlan_tag = 16'h7788;
    ud_source.vlan = 1'b1;
    status = cqe_codec.encode_with_entry_bytes_variant(
      ud_source, 32, RDMA_CQE_VARIANT_UD, ud_image);
    if (status == null || !status.ok() || ud_image == null) begin
      `uvm_error("CQE_VARIANT_READ_SETUP",
                 "failed to encode explicit UD CQE image")
    end
    else begin
      foreach (ud_image.bytes[i])
        mem.regions[0].data[192 + i] = ud_image.bytes[i];
      ud_decoded = null;
      image = null;
      status = submitter.read_cqe_sized_variant(
        target, 192, 32, RDMA_CQE_VARIANT_UD, ud_decoded, image);
      if (status == null || !status.ok() || ud_decoded == null ||
          ud_decoded.variant != RDMA_CQE_VARIANT_UD ||
          ud_decoded.ud_src_qpn != ud_source.ud_src_qpn ||
          ud_decoded.ud_smac != ud_source.ud_smac ||
          ud_decoded.ud_vlan_tag != ud_source.ud_vlan_tag)
        `uvm_error("CQE_VARIANT_READ",
                   "explicit UD CQE read did not preserve driver overlay")
    end

    status = submitter.release_target(target);
    if (status == null || !status.ok())
      `uvm_error("RELEASE", "queue target release failed")
    release_calls = 0;
    foreach (mem.calls[i])
      if (mem.calls[i].method_name == "release")
        release_calls++;
    // Exactly-once release: a duplicate release is rejected without another
    // adapter call.
    status = submitter.release_target(target);
    if (status == null || status.ok())
      `uvm_error("DUP_RELEASE", "duplicate target release was accepted")
    release_calls_after = 0;
    foreach (mem.calls[i])
      if (mem.calls[i].method_name == "release")
        release_calls_after++;
    if (release_calls != 1 || release_calls_after != release_calls)
      `uvm_error("DUP_RELEASE_CALL", "duplicate release invoked adapter")
    phase.drop_objection(this);
  endtask
endclass

// 中文设计：该 probe 只暴露测试需要观察的 private ledger 入口；生产对象仍然
// 只通过 opaque target 查找 mapping、request context 和 release authority。
// 功能：在 rdma_queue_host_mem_submitter_authority_probe 中提供受控的 ledger 查询和
//       lookup_target 调用，供 malformed-entry 测试验证 fail-closed 契约。
// 输入/输出及副作用：target、entry 为 lookup 输入/输出；entry_for 只返回测试观察用
//       的非拥有引用，probe_lookup_target 委托基类校验，不写 host memory。
// 失败/边界：target 为空或不在 probe ledger 中时 entry_for 返回 null；lookup 的错误和
//       null status 原样交给测试，不把未知 target 映射到默认 allocation。
class rdma_queue_host_mem_submitter_authority_probe
    extends rdma_queue_host_mem_submitter;
  `uvm_object_utils(rdma_queue_host_mem_submitter_authority_probe)

  // 功能：构造 authority probe，沿用 submitter 的空 host_mem、registry 和 ledger 初始状态。
  // 输入/输出及副作用：name（输入）；new 调用父类构造函数，不取得外部 mapping 或 adapter 所有权。
  // 失败/边界：构造只建立测试对象；未显式注入 host_mem/registry 时，所有业务入口仍应返回配置错误。
  function new(string name = "rdma_queue_host_mem_submitter_authority_probe");
    super.new(name);
  endfunction

  // 功能：entry_for 按 opaque target capability 取得测试要篡改的 ledger entry。
  // 输入/输出及副作用：target（输入）；函数仅读取 private ledger 并返回非拥有 entry 引用，不修改资源状态。
  // 失败/边界：target 为空、key 为空、ledger 未登记或记录为 null 时返回 null，绝不回退到其他 entry。
  function rdma_queue_host_mem_ledger_entry entry_for(
    rdma_queue_host_mem_target target
  );
    string key;

    if (target == null)
      return null;
    key = target.capability_key();
    if (key.len() == 0 || !ledger.exists(key))
      return null;
    return ledger[key];
  endfunction

  // 功能：probe_lookup_target 调用基类 lookup_target，观察 malformed ledger 是否在任何
  //       host-memory I/O 前被拒绝。
  // 输入/输出及副作用：target（输入）、entry（输出）；只执行 ledger/authority 校验，不写入或读取 backing。
  // 失败/边界：未知 target、缺失 request context/function 或过期 mapping 应返回非成功 status 且 entry 保持 null。
  function rdma_status probe_lookup_target(
    rdma_queue_host_mem_target target,
    output rdma_queue_host_mem_ledger_entry entry
  );
    return lookup_target(target, entry);
  endfunction
endclass

class rdma_queue_host_mem_submitter_authority_test extends uvm_test;
  `uvm_component_utils(rdma_queue_host_mem_submitter_authority_test)

  // 功能：构造 authority contract 测试组件，建立 UVM 层级对象但不绑定外部 adapter。
  // 输入/输出及副作用：name、parent（输入）；new 只调用 super.new，不创建 Host-memory allocation。
  // 失败/边界：依赖必须在 run_phase 中显式注入；未注入时测试应观察到配置错误而不是隐式成功。
  function new(string name = "rdma_queue_host_mem_submitter_authority_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：make_function 建立一个带非零 UID、object_id 和 generation 的 Function authority fixture。
  // 输入/输出及副作用：无显式输入；返回独立 Function handle，不修改 submitter 或 Host-memory ledger。
  // 失败/边界：fixture 的零 generation/错误 kind 会使 request_context.validate 拒绝，调用方不得把该失败当作 ledger 缺陷。
  function automatic rdma_function_handle make_function();
    rdma_function_handle function_h;

    function_h = rdma_function_handle::type_id::create("authority_function");
    function_h.function_uid = 64'h4455;
    function_h.object_id = 9;
    function_h.generation = 4;
    return function_h;
  endfunction

  // 功能：make_request_context 用上述 Function 构造完整 requester/PASID/domain
  //       DMA context，作为正常 allocation 的基线。
  // 输入/输出及副作用：无显式输入；返回独立 request context，调用方仍拥有 fixture，submitter allocate 时会再抓取快照。
  // 失败/边界：context 的 Function 必须保持 FUNCTION kind 且 generation 非零；
  // 本 fixture 不声明可选 route/epoch，以覆盖 legacy direct host-memory 合法路径。
  function automatic rdma_dma_request_context make_request_context();
    rdma_dma_request_context request_ctx;

    request_ctx = rdma_dma_request_context::type_id::create(
      "authority_request_ctx"
    );
    request_ctx.function_h = make_function();
    request_ctx.requester_bdf = 16'h0203;
    request_ctx.pasid_valid = 1'b1;
    request_ctx.pasid = 20'h23456;
    request_ctx.dma_domain_valid = 1'b1;
    request_ctx.dma_domain_id = 13;
    return request_ctx;
  endfunction

  // 功能：run_phase 分配一个合法 target 后清空 ledger entry.request_context，确认
  //       lookup_target 在发现不完整 authority 时 fail closed 且不返回可用 entry。
  // 输入/输出及副作用：phase（输入）；创建 mock allocation、注入 malformed ledger、执行断言并释放 allocation。
  // 失败/边界：若 malformed entry 被判成功或返回非空 entry，测试报告错误；清理失败也报告错误，不掩盖首个 authority 违规。
  task run_phase(uvm_phase phase);
    rdma_mock_host_mem mem;
    rdma_codec_registry registry;
    rdma_queue_host_mem_submitter_authority_probe submitter;
    rdma_dma_request_context request_ctx;
    rdma_queue_host_mem_target target;
    rdma_queue_host_mem_ledger_entry entry;
    rdma_queue_host_mem_ledger_entry found_entry;
    rdma_status status;
    int unsigned io_calls_before;
    int unsigned io_calls_after;

    phase.raise_objection(this);

    mem = rdma_mock_host_mem::type_id::create("authority_mem");
    registry = rdma_codec_registry::type_id::create("authority_registry");
    void'(rdma_register_queue_codecs(registry));
    submitter = rdma_queue_host_mem_submitter_authority_probe::type_id::create(
      "authority_submitter"
    );
    submitter.host_mem = mem;
    submitter.registry = registry;
    request_ctx = make_request_context();

    status = submitter.allocate_target(request_ctx, 256, 64,
                                       RDMA_DMA_BIDIRECTIONAL, target);
    if (status == null || !status.ok() || target == null) begin
      `uvm_error("AUTHORITY_SETUP", "failed to allocate authority target")
      phase.drop_objection(this);
      return;
    end

    entry = submitter.entry_for(target);
    if (entry == null || entry.request_context == null) begin
      `uvm_error("AUTHORITY_SETUP", "allocation did not create a complete ledger entry")
    end
    else begin
      io_calls_before = mem.calls.size();
      entry.request_context = null;
      found_entry = null;
      status = submitter.probe_lookup_target(target, found_entry);
      io_calls_after = mem.calls.size();

      if (status == null || status.ok() || found_entry != null)
        `uvm_error("MALFORMED_LEDGER_CONTEXT",
                   "lookup accepted a ledger entry without request_context")
      if (io_calls_after != io_calls_before)
        `uvm_error("MALFORMED_LEDGER_IO",
                   "malformed ledger lookup reached host-memory backend")

      // Restore the fixture only for deterministic cleanup; production code
      // never receives this mutable probe reference.
      entry.request_context = request_ctx;
    end

    status = submitter.release_target(target);
    if (status == null || !status.ok())
      `uvm_error("AUTHORITY_CLEANUP", "failed to release authority target")

    phase.drop_objection(this);
  endtask
endclass
