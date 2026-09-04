// 目录：测试层 unit/rdma_xtr_v1_qpc_codec_test.sv。
// 职责：验证 rdma_xtr_v1_qpc_codec_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_xtr_v1_qpc_codec_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_xtr_v1_qpc_codec_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_qpc_codec_test)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_qpc_codec_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：参数 label, status, expected 用于执行 expect_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：测试前置对象缺失时应报告断言错误并停止依赖该对象的后续检查。
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

  // 功能：在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：参数 label, RDMA_SC_OK 用于执行 expect_ok；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：测试前置对象缺失时应报告断言错误并停止依赖该对象的后续检查。
  function automatic void expect_ok(string label, rdma_status status);
    expect_status(label, status, RDMA_SC_OK);
  endfunction

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
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

  // 功能：执行 set_common_handles 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：参数 qpc, qpn, pd_id, send_cq_id, recv_cq_id, srq_id 用于执行 set_common_handles；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：set_common_handles 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function automatic void set_common_handles(
    rdma_qpc_model qpc,
    int unsigned qpn,
    int unsigned pd_id,
    int unsigned send_cq_id,
    int unsigned recv_cq_id,
    int signed srq_id = -1
  );
    qpc.qp_h = make_handle({qpc.get_name(), "_qp"}, RDMA_RESOURCE_QP, qpn);
    qpc.pd_h = make_handle({qpc.get_name(), "_pd"}, RDMA_RESOURCE_PD, pd_id);
    qpc.send_cq_h = make_handle({qpc.get_name(), "_scq"}, RDMA_RESOURCE_CQ,
                                send_cq_id);
    qpc.recv_cq_h = make_handle({qpc.get_name(), "_rcq"}, RDMA_RESOURCE_CQ,
                                recv_cq_id);
    if (srq_id >= 0)
      qpc.srq_h = make_handle({qpc.get_name(), "_srq"}, RDMA_RESOURCE_SRQ,
                              int'(srq_id));
    else
      qpc.srq_h = null;
  endfunction

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
  function automatic rdma_qpc_model make_rc(string name = "rc_qpc");
    rdma_qpc_model qpc;
    rdma_qpc_rc_ext ext;

    qpc = rdma_qpc_model::type_id::create(name);
    set_common_handles(qpc, 21'h15555, 16'ha55a, 20'habcde, 20'h54321,
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
    ext = rdma_qpc_rc_ext::type_id::create({name, "_ext"});
    ext.remote_qpn = 24'h654321;
    ext.send_psn = 24'habcdef;
    ext.recv_psn = 24'h123456;
    ext.retry_count = 7;
    ext.rnr_retry_count = 7;
    qpc.transport_ext = ext;
    return qpc;
  endfunction

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
  function automatic rdma_qpc_model make_ud(string name = "ud_qpc");
    rdma_qpc_model qpc;
    rdma_qpc_ud_ext ext;
    byte unsigned ip[16] = '{8'h20,8'h01,8'h0d,8'hb8,
                              8'h00,8'h00,8'h00,8'h00,
                              8'h00,8'h00,8'h00,8'h00,
                              8'h00,8'h00,8'h00,8'h01};

    qpc = rdma_qpc_model::type_id::create(name);
    set_common_handles(qpc, 21'h2aaaa, 16'h5aa5, 20'h13579, 20'h2468a);
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
    ext = rdma_qpc_ud_ext::type_id::create({name, "_ext"});
    ext.qkey = 32'h89abcdef;
    qpc.transport_ext = ext;
    return qpc;
  endfunction

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
  function automatic rdma_qpc_model make_urc(string name = "urc_qpc");
    rdma_qpc_model qpc;
    rdma_qpc_urc_ext ext;

    qpc = rdma_qpc_model::type_id::create(name);
    set_common_handles(qpc, 21'h3ffff, 16'hffff, 20'hfffff, 20'habcde);
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
    ext = rdma_qpc_urc_ext::type_id::create({name, "_ext"});
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

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  function automatic rdma_qpc_model clone_qpc(rdma_qpc_model source,
                                                string label);
    uvm_object cloned;
    rdma_qpc_model copy;
    cloned = source.clone();
    if (cloned == null || !$cast(copy, cloned)) begin
      `uvm_error(label, "QPC clone failed")
      return null;
    end
    return copy;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  function automatic rdma_hw_image clone_image(rdma_hw_image source,
                                                 string label);
    uvm_object cloned;
    rdma_hw_image copy;
    cloned = source.clone();
    if (cloned == null || !$cast(copy, cloned)) begin
      `uvm_error(label, "image clone failed")
      return null;
    end
    return copy;
  endfunction

  // 功能：处理 payload_equal：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 image, golden 用于执行 payload_equal；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：payload_equal 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function automatic bit payload_equal(rdma_hw_image image,
                                        rdma_xtr_v1_golden_case golden);
    if (image == null || golden == null || image.bytes.size() != 512 ||
        golden.payload.size() != 512)
      return 1'b0;
    foreach (golden.payload[i]) begin
      if (image.bytes[i] != golden.payload[i])
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：处理 image_payloads_equal：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 lhs, rhs 用于执行 image_payloads_equal；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：image_payloads_equal 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function automatic bit image_payloads_equal(rdma_hw_image lhs,
                                                rdma_hw_image rhs);
    if (lhs == null || rhs == null || lhs.bytes.size() != rhs.bytes.size())
      return 1'b0;
    foreach (lhs.bytes[i]) begin
      if (lhs.bytes[i] != rhs.bytes[i])
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
  function automatic rdma_xtr_v1_golden_case find_golden(
    rdma_xtr_v1_golden_case cases[$],
    string name
  );
    foreach (cases[i]) begin
      if (cases[i].name == name)
        return cases[i];
    end
    return null;
  endfunction

  // 功能：处理 qpc_key：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 key 用于执行 qpc_key；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：qpc_key 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function automatic rdma_codec_key qpc_key(string transport_variant);
    rdma_codec_key key;
    key.hw_version = "xtr_v1";
    key.image_kind = RDMA_IMAGE_QPC;
    key.object_type = "qpc";
    key.variant = transport_variant;
    key.opcode = XTR_V1_OP_QPC_CREATE;
    return key;
  endfunction

  // 功能：处理 copy_image_bytes：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 image, bytes 用于执行 copy_image_bytes；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：copy_image_bytes 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function automatic void copy_image_bytes(rdma_hw_image image,
                                             output byte unsigned bytes[]);
    bytes = new[image.bytes.size()];
    foreach (bytes[i]) bytes[i] = image.bytes[i];
  endfunction

  // 功能：处理 image_field：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 image, word_byte_offset, lsb, width 用于执行 image_field；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：image_field 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function automatic bit [63:0] image_field(
    rdma_hw_image image,
    int unsigned word_byte_offset,
    int unsigned lsb,
    int unsigned width
  );
    bit [63:0] word;
    bit [63:0] mask;
    word = '0;
    for (int unsigned i = 0; i < 8; i++)
      word[63 - (i * 8) -: 8] = image.bytes[word_byte_offset + i];
    mask = (width == 64) ? '1 : ((64'h1 << width) - 1);
    return (word >> lsb) & mask;
  endfunction

  // 功能：把输入模型字段按硬件布局编码到目标 image/缓冲区，并在写入前检查范围、重叠和保留位。
  // 输入/输出及副作用：参数 image, word_byte_offset, lsb, width, value 用于执行 set_image_field；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：镜像长度、字段宽度、保留位或写入范围非法时不修改已写入字节。
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
    word = '0;
    for (int unsigned i = 0; i < 8; i++)
      word[63 - (i * 8) -: 8] = image.bytes[word_byte_offset + i];
    width_mask = (width == 64) ? '1 : ((64'h1 << width) - 1);
    field_mask = width_mask << lsb;
    word = (word & ~field_mask) | ((value << lsb) & field_mask);
    for (int unsigned i = 0; i < 8; i++)
      image.bytes[word_byte_offset + i] = word[63 - (i * 8) -: 8];
  endfunction

  // 功能：在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：参数 label, codec, image 用于执行 expect_decode_failure；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：测试前置对象缺失时应报告断言错误并停止依赖该对象的后续检查。
  function automatic void expect_decode_failure(
    string label,
    rdma_codec_base codec,
    rdma_hw_image image
  );
    rdma_hw_model decoded;
    rdma_status status;
    decoded = make_rc({label, "_sentinel"});
    status = codec.decode(image, decoded);
    expect_status(label, status, RDMA_SC_CODEC_ERROR);
    if (decoded != null)
      `uvm_error(label, "failed decode published a model")
  endfunction

  // 功能：在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：参数 label, codec, model 用于执行 expect_encode_failure；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：测试前置对象缺失时应报告断言错误并停止依赖该对象的后续检查。
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

  // 功能：在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：参数 label, codec, lhs, rhs 用于执行 expect_serialized_inequality；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：测试前置对象缺失时应报告断言错误并停止依赖该对象的后续检查。
  function automatic void expect_serialized_inequality(
    string label,
    rdma_codec_base codec,
    rdma_hw_model lhs,
    rdma_hw_model rhs
  );
    rdma_status status;
    bit equal;
    string mismatch;
    status = codec.serialized_equal(lhs, rhs, equal, mismatch);
    expect_ok({label, "_STATUS"}, status);
    if (equal)
      `uvm_error(label, "serialized_equal accepted unequal models")
    if (mismatch.len() == 0)
      `uvm_error(label, "serialized_equal returned no useful mismatch")
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function automatic void check_golden_roundtrip(
    string label,
    rdma_codec_base codec,
    rdma_qpc_model source,
    rdma_xtr_v1_golden_case golden,
    output rdma_hw_image image,
    output rdma_qpc_model decoded
  );
    rdma_status status;
    rdma_hw_model decoded_model;
    bit equal;
    string mismatch;

    image = null;
    decoded = null;
    status = codec.encode(source, image);
    expect_ok({label, "_ENCODE"}, status);
    if (image == null) begin
      `uvm_error(label, "successful encode published null")
      return;
    end
    if (image.length != 512 || image.bytes.size() != 512 ||
        image.alignment != 512 || image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != RDMA_IMAGE_QPC ||
        image.hardware_version != XTR_V1_HW_VERSION ||
        image.function_generation != source.qp_h.generation ||
        image.write_target_kind != RDMA_HW_TARGET_NONE)
      `uvm_error(label, "encoded QPC metadata is not canonical")
    if (!payload_equal(image, golden))
      `uvm_error(label, "encoded payload differs from frozen 512-byte golden")
    if (image_field(image, XTR_V1_QPC_SQ_CE_EN_WORD_BYTE_OFFSET,
                    XTR_V1_QPC_SQ_CE_EN_LSB,
                    XTR_V1_QPC_SQ_CE_EN_WIDTH) != source.signature_enable)
      `uvm_error(label, "signature_enable did not map to SQ_CE_EN")

    decoded_model = null;
    status = codec.decode(image, decoded_model);
    expect_ok({label, "_DECODE"}, status);
    if (!$cast(decoded, decoded_model)) begin
      `uvm_error(label, "decode did not publish a QPC model")
      return;
    end
    status = codec.serialized_equal(source, decoded, equal, mismatch);
    expect_ok({label, "_EQUAL_STATUS"}, status);
    if (!equal)
      `uvm_error(label, {"round trip mismatch: ", mismatch})
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function automatic void check_equality_falsification(
    rdma_codec_base codec,
    rdma_qpc_model canonical
  );
    rdma_qpc_model changed;
    rdma_hw_model lhs;
    rdma_hw_model rhs;

    for (int unsigned mutation = 0; mutation < 12; mutation++) begin
      changed = clone_qpc(canonical, "EQUALITY_CLONE");
      case (mutation)
        0: changed.behavior.transport_version ^= 1;
        1: changed.behavior.migration_enable ^= 1;
        2: changed.behavior.tx_endian_swap ^= 1;
        3: changed.behavior.rx_endian_swap ^= 1;
        4: changed.behavior.read_after_write_fence ^= 1;
        5: changed.behavior.atomic_after_atomic_fence ^= 1;
        6: changed.behavior.\priority  ^= 1;
        7: changed.path_mtu_bytes = (changed.path_mtu_bytes == 8192) ? 4096 : 8192;
        8: changed.context_backing.value += 512;
        9: changed.signature_enable ^= 1;
        10: changed.tx_flow_control ^= 1;
        11: changed.rx_flow_control ^= 1;
      endcase
      lhs = canonical;
      rhs = changed;
      expect_serialized_inequality($sformatf("EQUALITY_MUTATION_%0d", mutation),
                                   codec, lhs, rhs);
    end
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function automatic void check_projected_handles(
    rdma_codec_base codec,
    rdma_qpc_model source,
    rdma_qpc_model decoded,
    rdma_hw_image first_image
  );
    rdma_qpc_model changed;
    rdma_hw_image changed_image;
    rdma_status status;
    bit equal;
    string mismatch;

    if (decoded.qp_h.function_uid != 0 || decoded.qp_h.generation != 0 ||
        decoded.pd_h.function_uid != 0 || decoded.pd_h.generation != 0 ||
        decoded.send_cq_h.function_uid != 0 ||
        decoded.send_cq_h.generation != 0 ||
        decoded.recv_cq_h.function_uid != 0 ||
        decoded.recv_cq_h.generation != 0 || decoded.srq_h == null ||
        decoded.srq_h.function_uid != 0 || decoded.srq_h.generation != 0)
      `uvm_error("PROJECTED_HANDLE", "decode restored lifecycle metadata")

    status = codec.serialized_equal(source, decoded, equal, mismatch);
    expect_ok("PROJECTED_HANDLE_EQUAL", status);
    if (!equal)
      `uvm_error("PROJECTED_HANDLE", {"projected handles differ: ", mismatch})

    changed = clone_qpc(source, "PROJECTED_CHANGED");
    changed.qp_h.function_uid++;
    changed.pd_h.function_uid++;
    changed.send_cq_h.function_uid++;
    changed.recv_cq_h.function_uid++;
    if (changed.srq_h != null) changed.srq_h.function_uid++;
    changed.qp_h.generation++;
    changed.pd_h.generation++;
    changed.send_cq_h.generation++;
    changed.recv_cq_h.generation++;
    if (changed.srq_h != null) changed.srq_h.generation++;
    status = codec.encode(changed, changed_image);
    expect_ok("PROJECTED_REENCODE", status);
    if (changed_image == null ||
        changed_image.function_generation != changed.qp_h.generation ||
        !image_payloads_equal(first_image, changed_image))
      `uvm_error("PROJECTED_REENCODE",
                 "lifecycle-only change altered payload or lost generation")
    status = codec.serialized_equal(source, changed, equal, mismatch);
    expect_ok("PROJECTED_LIFECYCLE_EQUAL", status);
    if (!equal)
      `uvm_error("PROJECTED_LIFECYCLE_EQUAL", mismatch)

    changed.qp_h.object_id++;
    expect_serialized_inequality("PROJECTED_OBJECT_ID", codec, source, changed);
    changed.qp_h.object_id--;
    changed.qp_h.kind = RDMA_RESOURCE_CQ;
    expect_serialized_inequality("PROJECTED_KIND", codec, source, changed);
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function automatic void check_access_normalization(
    string transport_label,
    rdma_codec_base codec,
    rdma_qpc_model source
  );
    rdma_qpc_model qpc;
    rdma_qpc_model decoded;
    rdma_hw_model decoded_model;
    rdma_hw_image image;
    rdma_status status;
    rdma_rdma_access_t original_access;
    rdma_rdma_access_t canonical_access;
    bit [4:0] expected_rights;
    bit [4:0] actual_rights;
    bit equal;
    string mismatch;
    string label;

    for (int unsigned which = 0; which < 3; which++) begin
      qpc = clone_qpc(source,
                      {transport_label, "_ACCESS_NORMALIZATION_CLONE"});
      qpc.access = '0;
      case (which)
        0: begin
          label = {transport_label, "_REMOTE_WRITE_ONLY"};
          qpc.access.remote_write = 1'b1;
          expected_rights = 5'h05;
        end
        1: begin
          label = {transport_label, "_REMOTE_ATOMIC_ONLY"};
          qpc.access.remote_atomic = 1'b1;
          expected_rights = 5'h11;
        end
        2: begin
          label = {transport_label, "_REMOTE_READ_ONLY"};
          qpc.access.remote_read = 1'b1;
          expected_rights = 5'h02;
        end
      endcase
      original_access = qpc.access;
      canonical_access = original_access;
      if (canonical_access.remote_write || canonical_access.remote_atomic)
        canonical_access.local_write = 1'b1;

      image = null;
      status = codec.encode(qpc, image);
      expect_ok({label, "_ENCODE"}, status);
      if (qpc.access != original_access)
        `uvm_error({label, "_INPUT"}, "encode modified the input access model")
      if (image == null) begin
        `uvm_error({label, "_IMAGE"}, "successful encode published null")
        continue;
      end
      actual_rights = image_field(
        image,
        XTR_V1_QPC_QP_ACCESS_FLAG_WORD_BYTE_OFFSET,
        XTR_V1_QPC_QP_ACCESS_FLAG_LSB,
        XTR_V1_QPC_QP_ACCESS_FLAG_WIDTH
      );
      if (actual_rights != expected_rights)
        `uvm_error({label, "_RIGHTS"},
                   $sformatf("QP_ACCESS_FLAG expected 0x%02h, got 0x%02h",
                             expected_rights, actual_rights))

      decoded_model = null;
      status = codec.decode(image, decoded_model);
      expect_ok({label, "_DECODE"}, status);
      if (!$cast(decoded, decoded_model)) begin
        `uvm_error({label, "_DECODE_TYPE"},
                   "decode did not publish a QPC model")
        continue;
      end
      if (decoded.access != canonical_access)
        `uvm_error({label, "_CANONICAL"},
                   "decode did not publish canonical access rights")
      status = codec.serialized_equal(qpc, decoded, equal, mismatch);
      expect_ok({label, "_EQUAL_STATUS"}, status);
      if (!equal)
        `uvm_error({label, "_EQUAL"},
                   {"normalized round trip mismatch: ", mismatch})
    end
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function automatic void check_access_equality_falsification(
    rdma_codec_base codec,
    rdma_qpc_model source
  );
    rdma_qpc_model no_access;
    rdma_qpc_model remote_read;
    rdma_status status;
    bit equal;
    string mismatch;

    no_access = clone_qpc(source, "ACCESS_EQUALITY_NONE_CLONE");
    remote_read = clone_qpc(source, "ACCESS_EQUALITY_REMOTE_READ_CLONE");
    no_access.access = '0;
    remote_read.access = '0;
    remote_read.access.remote_read = 1'b1;

    status = codec.serialized_equal(no_access, remote_read, equal, mismatch);
    expect_ok("ACCESS_EQUALITY_NEGATIVE_STATUS", status);
    if (equal)
      `uvm_error("ACCESS_EQUALITY_NEGATIVE",
                 "serialized_equal ignored distinct hardware access rights")
    if (mismatch != "access")
      `uvm_error("ACCESS_EQUALITY_MISMATCH",
                 $sformatf("expected access mismatch, got '%s'", mismatch))
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function automatic void check_pmtu_table(rdma_codec_base codec,
                                            rdma_qpc_model source);
    int unsigned mtus[4] = '{1024, 2048, 4096, 8192};
    int unsigned codes[4] = '{2, 3, 4, 5};
    int unsigned invalid_mtus[3] = '{256, 512, 1500};
    int unsigned invalid_codes[4] = '{0, 1, 6, 7};
    rdma_qpc_model qpc;
    rdma_qpc_model decoded;
    rdma_hw_model decoded_model;
    rdma_hw_image image;
    rdma_hw_image corrupt;
    rdma_status status;
    bit equal;
    string mismatch;

    foreach (mtus[i]) begin
      qpc = clone_qpc(source, "PMTU_VALID_CLONE");
      qpc.path_mtu_bytes = mtus[i];
      status = codec.encode(qpc, image);
      expect_ok($sformatf("PMTU_%0d_ENCODE", mtus[i]), status);
      if (image == null ||
          image_field(image, XTR_V1_QPC_PMTU_WORD_BYTE_OFFSET,
                      XTR_V1_QPC_PMTU_LSB, XTR_V1_QPC_PMTU_WIDTH) != codes[i])
        `uvm_error("PMTU_CODE", $sformatf("MTU %0d has wrong code", mtus[i]))
      decoded_model = null;
      status = codec.decode(image, decoded_model);
      expect_ok($sformatf("PMTU_%0d_DECODE", mtus[i]), status);
      if (!$cast(decoded, decoded_model) || decoded.path_mtu_bytes != mtus[i])
        `uvm_error("PMTU_INVERSE", "PMTU inverse mapping failed")
      else begin
        status = codec.serialized_equal(qpc, decoded, equal, mismatch);
        expect_ok("PMTU_EQUAL_STATUS", status);
        if (!equal) `uvm_error("PMTU_EQUAL", mismatch)
      end
    end
    foreach (invalid_mtus[i]) begin
      qpc = clone_qpc(source, "PMTU_INVALID_CLONE");
      qpc.path_mtu_bytes = invalid_mtus[i];
      expect_encode_failure($sformatf("PMTU_INVALID_%0d", invalid_mtus[i]),
                            codec, qpc);
    end
    status = codec.encode(source, image);
    expect_ok("PMTU_CORRUPT_SOURCE", status);
    foreach (invalid_codes[i]) begin
      corrupt = clone_image(image, "PMTU_CORRUPT_CLONE");
      set_image_field(corrupt, XTR_V1_QPC_PMTU_WORD_BYTE_OFFSET,
                      XTR_V1_QPC_PMTU_LSB, XTR_V1_QPC_PMTU_WIDTH,
                      invalid_codes[i]);
      expect_decode_failure($sformatf("PMTU_CODE_INVALID_%0d", invalid_codes[i]),
                            codec, corrupt);
    end
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function automatic void check_common_encode_invalid(
    rdma_codec_base codec,
    rdma_qpc_model source
  );
    rdma_qpc_model qpc;
    rdma_cqc_model wrong;
    rdma_qpc_ud_ext wrong_ext;
    rdma_qpc_rc_ext rc_ext;

    wrong = rdma_cqc_model::type_id::create("wrong_qpc_subclass");
    expect_encode_failure("WRONG_MODEL_SUBCLASS", codec, wrong);
    qpc = clone_qpc(source, "WRONG_EXT_CLONE");
    wrong_ext = rdma_qpc_ud_ext::type_id::create("wrong_ext");
    wrong_ext.qkey = 32'h1;
    qpc.transport_ext = wrong_ext;
    expect_encode_failure("WRONG_TRANSPORT_EXTENSION", codec, qpc);

    qpc = clone_qpc(source, "QPN_WIDTH_CLONE");
    qpc.qp_h.object_id = 1 << 21;
    expect_encode_failure("QPN_WIDTH", codec, qpc);
    qpc = clone_qpc(source, "CQN_WIDTH_CLONE");
    qpc.send_cq_h.object_id = 1 << 20;
    expect_encode_failure("CQN_WIDTH", codec, qpc);
    qpc = clone_qpc(source, "PD_WIDTH_CLONE");
    qpc.pd_h.object_id = 1 << 16;
    expect_encode_failure("PD_WIDTH", codec, qpc);
    qpc = clone_qpc(source, "BEHAVIOR_WIDTH_CLONE");
    qpc.behavior.transport_version = 4;
    expect_encode_failure("BEHAVIOR_TVER_WIDTH", codec, qpc);
    qpc = clone_qpc(source, "PRIORITY_WIDTH_CLONE");
    qpc.behavior.\priority  = 8;
    expect_encode_failure("BEHAVIOR_PRIORITY_WIDTH", codec, qpc);
    qpc = clone_qpc(source, "SQ_ALIGN_CLONE");
    qpc.sq_backing.value++;
    expect_encode_failure("SQ_ALIGNMENT", codec, qpc);
    qpc = clone_qpc(source, "RQ_ALIGN_CLONE");
    qpc.rq_backing.value++;
    expect_encode_failure("RQ_ALIGNMENT", codec, qpc);
    qpc = clone_qpc(source, "CTX_ALIGN_CLONE");
    qpc.context_backing.value++;
    expect_encode_failure("CONTEXT_ALIGNMENT", codec, qpc);
    qpc = clone_qpc(source, "TC_CLONE");
    qpc.address_vector.traffic_class ^= 1;
    expect_encode_failure("TRAFFIC_CLASS_ECN", codec, qpc);
    qpc = clone_qpc(source, "FLOW_CONTROL_CLONE");
    qpc.tx_flow_control ^= 1;
    expect_encode_failure("ASYMMETRIC_FLOW_CONTROL", codec, qpc);
    qpc = clone_qpc(source, "SQ_DEPTH_WIDTH_CLONE");
    qpc.sq_depth = 65536;
    expect_encode_failure("SQ_DEPTH_WIDTH", codec, qpc);
    qpc = clone_qpc(source, "RQ_DEPTH_WIDTH_CLONE");
    qpc.rq_depth = 65536;
    expect_encode_failure("RQ_DEPTH_WIDTH", codec, qpc);
    qpc = clone_qpc(source, "AV_SOURCE_WIDTH_CLONE");
    qpc.address_vector.source_address_index = 4096;
    expect_encode_failure("SOURCE_ADDRESS_INDEX_WIDTH", codec, qpc);
    qpc = clone_qpc(source, "STATE_INVALID_CLONE");
    qpc.state = rdma_qp_state_e'(15);
    expect_encode_failure("QP_STATE_INVALID", codec, qpc);
    qpc = clone_qpc(source, "LIFECYCLE_CLONE");
    qpc.pd_h.generation++;
    expect_encode_failure("HANDLE_LIFECYCLE_INVALID", codec, qpc);

    if (source.transport == RDMA_TRANSPORT_RC) begin
      qpc = clone_qpc(source, "RETRY_CLONE");
      if ($cast(rc_ext, qpc.transport_ext)) begin
        rc_ext.retry_count = 8;
        expect_encode_failure("RETRY_WIDTH", codec, qpc);
        rc_ext.retry_count = 7;
        rc_ext.rnr_retry_count = 8;
        expect_encode_failure("RNR_RETRY_WIDTH", codec, qpc);
      end
      qpc = clone_qpc(source, "SRQ_WIDTH_CLONE");
      qpc.srq_h.object_id = 1 << 15;
      expect_encode_failure("SRQ_WIDTH", codec, qpc);
    end
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function automatic void check_common_decode_invalid(
    rdma_codec_base codec,
    rdma_hw_image valid,
    bit check_rc_mirror
  );
    rdma_hw_image corrupt;

    corrupt = clone_image(valid, "META_LENGTH");
    corrupt.length = 511;
    expect_decode_failure("DECODE_LENGTH_METADATA", codec, corrupt);
    corrupt = clone_image(valid, "META_BYTES");
    void'(corrupt.bytes.pop_back());
    corrupt.length = 511;
    expect_decode_failure("DECODE_PAYLOAD_LENGTH", codec, corrupt);
    corrupt = clone_image(valid, "META_ALIGN");
    corrupt.alignment = 64;
    expect_decode_failure("DECODE_ALIGNMENT", codec, corrupt);
    corrupt = clone_image(valid, "META_ENDIAN");
    corrupt.endian = RDMA_ENDIAN_LITTLE;
    expect_decode_failure("DECODE_ENDIAN", codec, corrupt);
    corrupt = clone_image(valid, "META_KIND");
    corrupt.image_kind = RDMA_IMAGE_CQC;
    expect_decode_failure("DECODE_KIND", codec, corrupt);
    corrupt = clone_image(valid, "META_VERSION");
    corrupt.hardware_version++;
    expect_decode_failure("DECODE_VERSION", codec, corrupt);
    corrupt = clone_image(valid, "META_TARGET");
    corrupt.write_target_kind = RDMA_HW_TARGET_BACKING;
    expect_decode_failure("DECODE_TARGET", codec, corrupt);
    corrupt = clone_image(valid, "META_INACTIVE_TARGET");
    corrupt.backing_target.value = 64'h1000;
    expect_decode_failure("DECODE_INACTIVE_TARGET", codec, corrupt);
    corrupt = clone_image(valid, "RESERVED_PRIVATE");
    set_image_field(corrupt, 104, 0, 1, 1);
    expect_decode_failure("DECODE_PRIVATE_RESERVED", codec, corrupt);
    corrupt = clone_image(valid, "STATE_CODE_INVALID");
    set_image_field(corrupt, XTR_V1_QPC_QP_ST_WORD_BYTE_OFFSET,
                    XTR_V1_QPC_QP_ST_LSB, XTR_V1_QPC_QP_ST_WIDTH, 6);
    expect_decode_failure("DECODE_STATE_CODE", codec, corrupt);
    corrupt = clone_image(valid, "SERVICE_CODE_INVALID");
    set_image_field(corrupt, XTR_V1_QPC_SERVICE_TYPE_WORD_BYTE_OFFSET,
                    XTR_V1_QPC_SERVICE_TYPE_LSB,
                    XTR_V1_QPC_SERVICE_TYPE_WIDTH,
                    image_field(corrupt,
                      XTR_V1_QPC_SERVICE_TYPE_WORD_BYTE_OFFSET,
                      XTR_V1_QPC_SERVICE_TYPE_LSB,
                      XTR_V1_QPC_SERVICE_TYPE_WIDTH) ^ 1);
    expect_decode_failure("DECODE_SERVICE_CODE", codec, corrupt);
    corrupt = clone_image(valid, "ECN_INVALID");
    set_image_field(corrupt, XTR_V1_QPC_ECN_WORD_BYTE_OFFSET,
                    XTR_V1_QPC_ECN_LSB, XTR_V1_QPC_ECN_WIDTH,
                    image_field(corrupt, XTR_V1_QPC_ECN_WORD_BYTE_OFFSET,
                                XTR_V1_QPC_ECN_LSB,
                                XTR_V1_QPC_ECN_WIDTH) ^ 2);
    expect_decode_failure("DECODE_TRAFFIC_CLASS", codec, corrupt);
    corrupt = clone_image(valid, "ICOS_INVALID");
    set_image_field(corrupt, XTR_V1_QPC_ICOS_WORD_BYTE_OFFSET,
                    XTR_V1_QPC_ICOS_LSB, XTR_V1_QPC_ICOS_WIDTH,
                    image_field(corrupt, XTR_V1_QPC_ICOS_WORD_BYTE_OFFSET,
                                XTR_V1_QPC_ICOS_LSB,
                                XTR_V1_QPC_ICOS_WIDTH) ^ 1);
    expect_decode_failure("DECODE_ICOS_MIRROR", codec, corrupt);
    corrupt = clone_image(valid, "FWD_INVALID");
    set_image_field(corrupt, XTR_V1_QPC_FWD_WORD_BYTE_OFFSET,
                    XTR_V1_QPC_FWD_LSB, XTR_V1_QPC_FWD_WIDTH, 1);
    expect_decode_failure("DECODE_FORWARDING_CODE", codec, corrupt);
    if (check_rc_mirror) begin
      corrupt = clone_image(valid, "RC_MIRROR");
      set_image_field(corrupt, XTR_V1_QPC_RC_LAST_READ_PSN_WORD_BYTE_OFFSET,
                      XTR_V1_QPC_RC_LAST_READ_PSN_LSB,
                      XTR_V1_QPC_RC_LAST_READ_PSN_WIDTH, 24'habcdef - 1);
      expect_decode_failure("DECODE_RC_PSN_MIRROR", codec, corrupt);
    end
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function automatic void check_urc_owner_routing(rdma_codec_base codec,
                                                   rdma_qpc_model source);
    rdma_qpc_model qpc;
    rdma_qpc_model decoded;
    rdma_qpc_urc_ext ext;
    rdma_hw_image image;
    rdma_hw_model decoded_model;
    rdma_xtr_v1_qword_builder builder;
    byte unsigned bytes[];
    bit [63:0] value;
    bit equal;
    string mismatch;
    rdma_status status;

    qpc = clone_qpc(source, "URC_OWNER_SOURCE");
    if (!$cast(ext, qpc.transport_ext)) begin
      `uvm_error("URC_OWNER", "URC extension cast failed")
      return;
    end
    ext.remote_qpn = 24'h123456;
    ext.dbsn = 24'h234567;
    ext.queues.rsq_depth = 32;
    ext.queues.rdsq_depth = 128;
    ext.queues.rdsq_fetch_count = 7;
    ext.queues.dsq_fetch_count = 13;
    status = codec.encode(qpc, image);
    expect_ok("URC_OWNER_ENCODE", status);
    builder = new("urc_owner_builder");
    copy_image_bytes(image, bytes);
    expect_ok("URC_OWNER_DESERIALIZE", builder.deserialize(bytes));
`define CHECK_URC_OWNER_FIELD(LABEL, STEM, EXPECTED) \
    value = '0; \
    expect_ok({"URC_OWNER_", LABEL}, \
              builder.get_field(STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \
                                STEM``_WIDTH, value)); \
    if (value != EXPECTED) \
      `uvm_error({"URC_OWNER_", LABEL}, \
                 $sformatf("expected 0x%0x, got 0x%0x", EXPECTED, value));
    `CHECK_URC_OWNER_FIELD("DST_QPN", XTR_V1_QPC_DST_QPN, 24'h123456)
    `CHECK_URC_OWNER_FIELD("TX_DBSN", XTR_V1_QPC_URC_TX_DBSN, 24'h234567)
    `CHECK_URC_OWNER_FIELD("RX_DBSN", XTR_V1_QPC_URC_RX_DBSN, 24'h234567)
    `CHECK_URC_OWNER_FIELD("RXED_DBSN", XTR_V1_QPC_URC_RXED_DBSN, 24'h234567)
    `CHECK_URC_OWNER_FIELD("RSQ_SIZE", XTR_V1_QPC_URC_RSQ_SIZE, 5)
    `CHECK_URC_OWNER_FIELD("RDSQ_SIZE", XTR_V1_QPC_URC_RDSQ_SIZE, 7)
    `CHECK_URC_OWNER_FIELD("RDSQ_FETCH", XTR_V1_QPC_URC_NXT_RDSQ_FETCH_NUM, 7)
    `CHECK_URC_OWNER_FIELD("DSQ_FETCH", XTR_V1_QPC_URC_NXT_DSQ_FETCH_NUM, 13)
`undef CHECK_URC_OWNER_FIELD
    decoded_model = null;
    status = codec.decode(image, decoded_model);
    expect_ok("URC_OWNER_DECODE", status);
    if (!$cast(decoded, decoded_model))
      `uvm_error("URC_OWNER", "decode type mismatch")
    else begin
      status = codec.serialized_equal(qpc, decoded, equal, mismatch);
      expect_ok("URC_OWNER_EQUAL_STATUS", status);
      if (!equal) `uvm_error("URC_OWNER_EQUAL", mismatch)
    end
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function automatic void check_urc_mutations(rdma_codec_base codec,
                                               rdma_qpc_model source,
                                               rdma_hw_image valid);
    int unsigned mirror_word[9] = '{96, 128, 96, 128, 296,
                                     232, 400, 232, 416};
    int unsigned mirror_lsb[9] = '{24, 24, 0, 0, 0, 0, 40, 24, 40};
    int unsigned runtime_word[3] = '{224, 328, 328};
    int unsigned runtime_lsb[3] = '{24, 24, 0};
    int unsigned value_word[6] = '{24, 32, 224, 416, 320, 320};
    int unsigned value_lsb[6] = '{59, 8, 16, 32, 20, 16};
    int unsigned value_width[6] = '{3, 3, 6, 6, 4, 4};
    int unsigned value_new[6] = '{5, 7, 7, 13, 10, 11};
    rdma_hw_image corrupt;
    rdma_hw_model decoded_model;
    rdma_qpc_model decoded;
    rdma_qpc_urc_ext decoded_ext;
    rdma_status status;
    bit equal;
    string mismatch;

    foreach (mirror_word[i]) begin
      corrupt = clone_image(valid, "URC_MIRROR_CLONE");
      set_image_field(corrupt, mirror_word[i], mirror_lsb[i], 24,
                      image_field(corrupt, mirror_word[i], mirror_lsb[i], 24) ^ 1);
      expect_decode_failure($sformatf("URC_MIRROR_%0d", i), codec, corrupt);
    end
    foreach (runtime_word[i]) begin
      corrupt = clone_image(valid, "URC_RUNTIME_CLONE");
      set_image_field(corrupt, runtime_word[i], runtime_lsb[i], 24, 1);
      expect_decode_failure($sformatf("URC_RUNTIME_%0d", i), codec, corrupt);
    end
    foreach (value_word[i]) begin
      corrupt = clone_image(valid, "URC_VALUE_CLONE");
      set_image_field(corrupt, value_word[i], value_lsb[i], value_width[i],
                      value_new[i]);
      decoded_model = null;
      status = codec.decode(corrupt, decoded_model);
      expect_ok($sformatf("URC_VALUE_%0d_DECODE", i), status);
      if (!$cast(decoded, decoded_model) ||
          !$cast(decoded_ext, decoded.transport_ext)) begin
        `uvm_error("URC_VALUE", "representable mutation did not publish URC")
      end else begin
        case (i)
          0: if (decoded_ext.queues.rsq_depth != 32)
               `uvm_error("URC_RSQ_INVERSE", "depth inverse mismatch")
          1: if (decoded_ext.queues.rdsq_depth != 128)
               `uvm_error("URC_RDSQ_INVERSE", "depth inverse mismatch")
          2: if (decoded_ext.queues.rdsq_fetch_count != 7)
               `uvm_error("URC_RDSQ_FETCH_INVERSE", "fetch inverse mismatch")
          3: if (decoded_ext.queues.dsq_fetch_count != 13)
               `uvm_error("URC_DSQ_FETCH_INVERSE", "fetch inverse mismatch")
          4: if (decoded_ext.queues.rq_sequence_threshold_entries != 1024)
               `uvm_error("URC_RQ_TH_INVERSE", "threshold inverse mismatch")
          5: if (decoded_ext.queues.sq_completion_threshold_entries != 2048)
               `uvm_error("URC_SQ_TH_INVERSE", "threshold inverse mismatch")
        endcase
        status = codec.serialized_equal(source, decoded, equal, mismatch);
        expect_ok("URC_VALUE_EQUAL_STATUS", status);
        if (equal || mismatch.len() == 0)
          `uvm_error("URC_VALUE_EQUAL", "mutation was not distinguished")
      end
    end

    corrupt = clone_image(valid, "URC_DSQ_RELATION");
    set_image_field(corrupt, XTR_V1_QPC_URC_NXT_DSQ_PBA_WORD_BYTE_OFFSET,
                    XTR_V1_QPC_URC_NXT_DSQ_PBA_LSB,
                    XTR_V1_QPC_URC_NXT_DSQ_PBA_WIDTH,
                    image_field(corrupt,
                      XTR_V1_QPC_URC_NXT_DSQ_PBA_WORD_BYTE_OFFSET,
                      XTR_V1_QPC_URC_NXT_DSQ_PBA_LSB,
                      XTR_V1_QPC_URC_NXT_DSQ_PBA_WIDTH) + 1);
    expect_decode_failure("URC_DSQ_RELATION", codec, corrupt);
    corrupt = clone_image(valid, "URC_RESERVED");
    set_image_field(corrupt, XTR_V1_QPC_CC_TYPE_WORD_BYTE_OFFSET,
                    XTR_V1_QPC_CC_TYPE_LSB, XTR_V1_QPC_CC_TYPE_WIDTH, 1);
    expect_decode_failure("URC_CC_RESERVED", codec, corrupt);
    corrupt = clone_image(valid, "URC_RTO_RESERVED");
    set_image_field(corrupt, XTR_V1_QPC_RTO_CODE_WORD_BYTE_OFFSET,
                    XTR_V1_QPC_RTO_CODE_LSB, XTR_V1_QPC_RTO_CODE_WIDTH, 1);
    expect_decode_failure("URC_RTO_RESERVED", codec, corrupt);
    corrupt = clone_image(valid, "URC_LOAD_RESERVED");
    set_image_field(corrupt, XTR_V1_QPC_LOAD_RQ_PI_TH_WORD_BYTE_OFFSET,
                    XTR_V1_QPC_LOAD_RQ_PI_TH_LSB,
                    XTR_V1_QPC_LOAD_RQ_PI_TH_WIDTH, 1);
    expect_decode_failure("URC_LOAD_RESERVED", codec, corrupt);
    corrupt = clone_image(valid, "URC_RQ_THRESHOLD_TOPOLOGY");
    set_image_field(corrupt, XTR_V1_QPC_URC_RQ_SE_TH_WORD_BYTE_OFFSET,
                    XTR_V1_QPC_URC_RQ_SE_TH_LSB,
                    XTR_V1_QPC_URC_RQ_SE_TH_WIDTH, 15);
    expect_decode_failure("URC_RQ_THRESHOLD_TOPOLOGY", codec, corrupt);
    corrupt = clone_image(valid, "URC_SQ_THRESHOLD_TOPOLOGY");
    set_image_field(corrupt, XTR_V1_QPC_SQ_SIZE_WORD_BYTE_OFFSET,
                    XTR_V1_QPC_SQ_SIZE_LSB, XTR_V1_QPC_SQ_SIZE_WIDTH, 11);
    expect_decode_failure("URC_SQ_THRESHOLD_TOPOLOGY", codec, corrupt);
    corrupt = clone_image(valid, "URC_DST_ZERO");
    set_image_field(corrupt, XTR_V1_QPC_DST_QPN_WORD_BYTE_OFFSET,
                    XTR_V1_QPC_DST_QPN_LSB, XTR_V1_QPC_DST_QPN_WIDTH, 0);
    expect_decode_failure("URC_DST_QPN_ZERO", codec, corrupt);

    corrupt = clone_image(valid, "URC_DSQ_WRAP");
    set_image_field(corrupt, XTR_V1_QPC_URC_CUR_DSQ_PBA_H_WORD_BYTE_OFFSET,
                    XTR_V1_QPC_URC_CUR_DSQ_PBA_H_LSB,
                    XTR_V1_QPC_URC_CUR_DSQ_PBA_H_WIDTH, 40'hffffffffff);
    set_image_field(corrupt, XTR_V1_QPC_URC_CUR_DSQ_PBA_L_WORD_BYTE_OFFSET,
                    XTR_V1_QPC_URC_CUR_DSQ_PBA_L_LSB,
                    XTR_V1_QPC_URC_CUR_DSQ_PBA_L_WIDTH, 12'hfff);
    set_image_field(corrupt, XTR_V1_QPC_URC_NXT_DSQ_PBA_WORD_BYTE_OFFSET,
                    XTR_V1_QPC_URC_NXT_DSQ_PBA_LSB,
                    XTR_V1_QPC_URC_NXT_DSQ_PBA_WIDTH, 0);
    expect_decode_failure("URC_DSQ_WRAP", codec, corrupt);
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function automatic void check_urc_encode_bounds(rdma_codec_base codec,
                                                   rdma_qpc_model source);
    rdma_qpc_model qpc;
    rdma_qpc_model decoded;
    rdma_qpc_urc_ext ext;
    rdma_qpc_urc_ext decoded_ext;
    rdma_hw_image image;
    rdma_hw_model decoded_model;
    rdma_status status;
    bit equal;
    string mismatch;

    for (int unsigned which = 0; which < 12; which++) begin
      qpc = clone_qpc(source, "URC_ENCODE_BOUND_CLONE");
      if (!$cast(ext, qpc.transport_ext)) begin
        `uvm_error("URC_ENCODE_BOUND", "extension cast failed")
        return;
      end
      case (which)
        0: ext.queues.rsq_depth = 256;
        1: ext.queues.rdsq_depth = 256;
        2: ext.queues.rdsq_fetch_count = 64;
        3: ext.queues.dsq_fetch_count = 64;
        4: ext.queues.rq_sequence_threshold_entries = 65536;
        5: ext.queues.sq_completion_threshold_entries = 65536;
        6: ext.queues.dsq_backing.value = 64'hffff_ffff_ffff_f000;
        7: ext.remote_qpn = 0;
        8: ext.queues.rsq_backing.value++;
        9: ext.queues.rdsq_backing.value++;
        10: ext.queues.dsq_backing.value++;
        11: ext.queues = null;
      endcase
      if (which == 4) qpc.rq_depth = 131072;
      if (which == 5) qpc.sq_depth = 131072;
      expect_encode_failure($sformatf("URC_ENCODE_BOUND_%0d", which), codec, qpc);
    end

    qpc = clone_qpc(source, "URC_MAX_BACKING");
    if (!$cast(ext, qpc.transport_ext)) return;
    ext.queues.rsq_backing.value = 64'hffff_ffff_ffff_f000;
    ext.queues.rdsq_backing.value = 64'hffff_ffff_ffff_f000;
    status = codec.encode(qpc, image);
    expect_ok("URC_MAX_BACKING_ENCODE", status);
    decoded_model = null;
    status = codec.decode(image, decoded_model);
    expect_ok("URC_MAX_BACKING_DECODE", status);
    if (!$cast(decoded, decoded_model) ||
        !$cast(decoded_ext, decoded.transport_ext) ||
        decoded_ext.queues.rsq_backing.value != 64'hffff_ffff_ffff_f000 ||
        decoded_ext.queues.rdsq_backing.value != 64'hffff_ffff_ffff_f000)
      `uvm_error("URC_MAX_BACKING", "52-bit page maximum did not round trip")
    else begin
      status = codec.serialized_equal(qpc, decoded, equal, mismatch);
      expect_ok("URC_MAX_BACKING_EQUAL_STATUS", status);
      if (!equal) `uvm_error("URC_MAX_BACKING_EQUAL", mismatch)
    end

    qpc = clone_qpc(source, "URC_THRESHOLD_ZERO");
    if (!$cast(ext, qpc.transport_ext)) return;
    ext.queues.rq_sequence_threshold_entries = 0;
    ext.queues.sq_completion_threshold_entries = 0;
    status = codec.encode(qpc, image);
    expect_ok("URC_THRESHOLD_ZERO_ENCODE", status);
    decoded_model = null;
    status = codec.decode(image, decoded_model);
    expect_ok("URC_THRESHOLD_ZERO_DECODE", status);
    if (!$cast(decoded, decoded_model) ||
        !$cast(decoded_ext, decoded.transport_ext) ||
        decoded_ext.queues.rq_sequence_threshold_entries != 0 ||
        decoded_ext.queues.sq_completion_threshold_entries != 0)
      `uvm_error("URC_THRESHOLD_ZERO", "zero threshold did not round trip")

    qpc = clone_qpc(source, "URC_GENERIC_EXPRESSIVE");
    if (!$cast(ext, qpc.transport_ext)) return;
    qpc.sq_depth = 131072;
    qpc.rq_depth = 131072;
    ext.queues.rsq_depth = 1024;
    ext.queues.rdsq_depth = 2048;
    ext.queues.rdsq_fetch_count = 1000;
    ext.queues.dsq_fetch_count = 2000;
    ext.queues.rq_sequence_threshold_entries = 65536;
    ext.queues.sq_completion_threshold_entries = 131072;
    expect_ok("URC_GENERIC_EXPRESSIVE_MODEL", qpc.validate());
  endfunction

  // 功能：驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase 控制 UVM 调度；task 驱动事务、断言和 objection，测试 fixture 由本层负责清理。
  //   阶段提前结束或前置 setup 失败时必须释放 objection 并停止后续访问。
  // 失败/边界：setup 失败或阶段被终止时停止新增事务，确保 objection、临时对象和外部引用按测试生命周期收尾。
  task run_phase(uvm_phase phase);
    rdma_codec_registry registry;
    rdma_codec_base rc_codec;
    rdma_codec_base ud_codec;
    rdma_codec_base urc_codec;
    rdma_codec_base missing_codec;
    rdma_status status;
    rdma_xtr_v1_golden_case cases[$];
    rdma_xtr_v1_golden_case rc_golden;
    rdma_xtr_v1_golden_case ud_golden;
    rdma_xtr_v1_golden_case urc_golden;
    string error;
    string registered_keys[$];
    rdma_qpc_model rc_source;
    rdma_qpc_model ud_source;
    rdma_qpc_model urc_source;
    rdma_qpc_model rc_decoded;
    rdma_qpc_model ud_decoded;
    rdma_qpc_model urc_decoded;
    rdma_qpc_model maxima;
    rdma_qpc_model maxima_decoded;
    rdma_qpc_model canonical_state;
    rdma_qpc_model canonical_state_decoded;
    rdma_qpc_model invalid_ud;
    rdma_hw_model decoded_model;
    rdma_hw_image rc_image;
    rdma_hw_image ud_image;
    rdma_hw_image urc_image;
    rdma_hw_image maxima_image;
    rdma_hw_image canonical_state_image;
    rdma_hw_image corrupt_image;
    bit equal;
    string mismatch;

    phase.raise_objection(this);

    registry = rdma_codec_registry::type_id::create("private_qpc_registry");
    registry.clear();
    status = rdma_xtr_v1_register_qpc_codecs(registry);
    expect_ok("REGISTER_QPC_CODECS", status);
    expect_ok("LOOKUP_RC", registry.lookup(qpc_key("rc"), rc_codec));
    expect_ok("LOOKUP_UD", registry.lookup(qpc_key("ud"), ud_codec));
    expect_ok("LOOKUP_URC", registry.lookup(qpc_key("urc"), urc_codec));
    registry.list_keys(registered_keys);
    if (registered_keys.size() != 3 ||
        registered_keys[0] != "xtr_v1|1|qpc|rc|00" ||
        registered_keys[1] != "xtr_v1|1|qpc|ud|00" ||
        registered_keys[2] != "xtr_v1|1|qpc|urc|00")
      `uvm_error("REGISTER_QPC_KEYS",
                 "QPC helper did not register exactly the three stable keys")
    expect_status("LOOKUP_ABSENT_VARIANT",
                  registry.lookup('{"xtr_v1", RDMA_IMAGE_QPC, "qpc",
                                    "reserved", XTR_V1_OP_QPC_CREATE},
                                  missing_codec),
                  RDMA_SC_UNSUPPORTED_OPCODE);
    if (missing_codec != null)
      `uvm_error("LOOKUP_ABSENT_VARIANT", "failed lookup published a codec")

    if (!rdma_xtr_v1_golden_reader::read_all(
          "../hw/xtr_v1/golden_vectors/context.hex", cases, error)) begin
      `uvm_fatal("QPC_GOLDEN_READ", error)
    end

    rc_golden = find_golden(cases, "qpc_rc_boundary");
    ud_golden = find_golden(cases, "qpc_ud_boundary");
    urc_golden = find_golden(cases, "qpc_urc_boundary");
    if (rc_golden == null || ud_golden == null || urc_golden == null)
      `uvm_fatal("QPC_GOLDEN_FIND", "required QPC golden is absent")

    rc_source = make_rc();
    ud_source = make_ud();
    urc_source = make_urc();
    check_access_normalization("RC", rc_codec, rc_source);
    check_access_normalization("UD", ud_codec, ud_source);
    check_access_normalization("URC", urc_codec, urc_source);
    check_access_equality_falsification(rc_codec, rc_source);
    canonical_state = clone_qpc(rc_source, "sqe_canonical_source");
    canonical_state.state = RDMA_QPS_SQE;
    status = rc_codec.encode(canonical_state, canonical_state_image);
    expect_ok("SQE_CANONICAL_ENCODE", status);
    decoded_model = null;
    status = rc_codec.decode(canonical_state_image, decoded_model);
    expect_ok("SQE_CANONICAL_DECODE", status);
    if (!$cast(canonical_state_decoded, decoded_model) ||
        canonical_state_decoded.state != RDMA_QPS_SQD)
      `uvm_error("SQE_CANONICAL", "hardware state 5 did not decode as SQD")
    else begin
      status = rc_codec.serialized_equal(canonical_state,
                                         canonical_state_decoded,
                                         equal, mismatch);
      expect_ok("SQE_CANONICAL_EQUAL_STATUS", status);
      if (!equal) `uvm_error("SQE_CANONICAL_EQUAL", mismatch)
    end
    check_golden_roundtrip("RC_GOLDEN", rc_codec, rc_source, rc_golden,
                           rc_image, rc_decoded);
    check_golden_roundtrip("UD_GOLDEN", ud_codec, ud_source, ud_golden,
                           ud_image, ud_decoded);
    check_golden_roundtrip("URC_GOLDEN", urc_codec, urc_source, urc_golden,
                           urc_image, urc_decoded);

    if (rc_decoded != null) begin
      check_projected_handles(rc_codec, rc_source, rc_decoded, rc_image);
      check_equality_falsification(rc_codec, rc_decoded);
    end

    maxima = clone_qpc(rc_source, "behavior_maxima");
    maxima.behavior.transport_version = 3;
    maxima.behavior.\priority  = 7;
    maxima.tx_flow_control = 1'b0;
    maxima.rx_flow_control = 1'b0;
    status = rc_codec.encode(maxima, maxima_image);
    expect_ok("BEHAVIOR_MAXIMA_ENCODE", status);
    decoded_model = null;
    status = rc_codec.decode(maxima_image, decoded_model);
    expect_ok("BEHAVIOR_MAXIMA_DECODE", status);
    if (!$cast(maxima_decoded, decoded_model))
      `uvm_error("BEHAVIOR_MAXIMA", "decode type mismatch")
    else begin
      status = rc_codec.serialized_equal(maxima, maxima_decoded, equal, mismatch);
      expect_ok("BEHAVIOR_MAXIMA_EQUAL_STATUS", status);
      if (!equal) `uvm_error("BEHAVIOR_MAXIMA_EQUAL", mismatch)
    end

    check_pmtu_table(rc_codec, rc_source);
    check_common_encode_invalid(rc_codec, rc_source);
    check_common_decode_invalid(rc_codec, rc_image, 1'b1);
    check_common_decode_invalid(ud_codec, ud_image, 1'b0);
    check_common_decode_invalid(urc_codec, urc_image, 1'b0);
    invalid_ud = clone_qpc(ud_source, "invalid_ud_qkey");
    begin
      rdma_qpc_ud_ext invalid_ud_ext;
      if ($cast(invalid_ud_ext, invalid_ud.transport_ext))
        invalid_ud_ext.qkey = 0;
    end
    expect_encode_failure("UD_QKEY_ZERO", ud_codec, invalid_ud);
    corrupt_image = clone_image(ud_image, "ud_qkey_mirror");
    set_image_field(corrupt_image, XTR_V1_QPC_DST_QPN_WORD_BYTE_OFFSET,
                    XTR_V1_QPC_DST_QPN_LSB, XTR_V1_QPC_DST_QPN_WIDTH,
                    image_field(corrupt_image,
                      XTR_V1_QPC_DST_QPN_WORD_BYTE_OFFSET,
                      XTR_V1_QPC_DST_QPN_LSB,
                      XTR_V1_QPC_DST_QPN_WIDTH) ^ 1);
    expect_decode_failure("UD_QKEY_DST_MIRROR", ud_codec, corrupt_image);
    check_urc_owner_routing(urc_codec, urc_source);
    check_urc_mutations(urc_codec, urc_source, urc_image);
    check_urc_encode_bounds(urc_codec, urc_source);

    phase.drop_objection(this);
  endtask
endclass
