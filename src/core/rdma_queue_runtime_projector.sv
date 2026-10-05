// 目录/层次：src/core 的 runtime 值投影层。
// 职责：深复制 request/slot/pending 对象图并比较恢复证据，保留 runtime 状态构造策略。
// 依赖：types/model、runtime transaction 值类型与 UVM raw factory；不依赖 runtime 实例。
// 所有权/生命周期：无字段、锁、缓存、UVM 注册或 provider 实例；只处理显式输入值，调用方拥有输入与结果，
//  runtime 仍唯一负责锁、authority、PI/CI/credit 与恢复阶段提交。
// 设计：static automatic 保证每次调用局部值独立；无状态不等于无分配/无回调，raw factory 的调用顺序、
//  对象名与 status fallback 保持原契约，不检测恶意工厂 alias；输入为 live ledger 时调用方须维持原锁窗口。

class rdma_queue_runtime_projector;

  // 功能：绕过 registry::create() 的 FCTTYP fatal，从 UVM factory 取原始对象，由调用方显式类型转换。
  // 输入/输出及副作用：requested_type/name 输入；返回 factory 创建的 uvm_object，不改 runtime。
  // 失败/边界：requested_type、全局 factory 或创建结果为 null 时返回 null，不报 fatal；转换失败由调用方归一为非成功。
  static function automatic uvm_object factory_create_object_nonfatal(
    uvm_object_wrapper requested_type,
    string name
  );
    uvm_factory factory;

    if (requested_type == null)
      return null;
    factory = uvm_factory::get();
    if (factory == null)
      return null;
    return factory.create_object_by_type(requested_type, "", name);
  endfunction

  // 功能：统一构造 runtime 对外 status；factory 被注入 null/错类型时改用直接构造的非空 fallback。
  // 输入/输出及副作用：code/message 输入；经 rdma_status 的无分配 setter 初始化全部字段。
  // 失败/边界：factory 失败时仍返回同一 code/message，不把错误码伪造成成功。
  static function automatic rdma_status make_runtime_status(
    rdma_status_code_e code, string message = ""
  );
    rdma_status result;
    uvm_object raw_result;

    // // 不调用 rdma_status::make()/type_id::create：二者在 null 或错类型 factory 上会先报 FCTTYP fatal，
    // // 使调用方拿不到错误码。
    raw_result = factory_create_object_nonfatal(rdma_status::get_type(),
                                                 "runtime_status");
    if (raw_result == null || !$cast(result, raw_result)) begin
      result = new("runtime_status_fallback");
    end
    void'(rdma_status::set_fields_noalloc(result, code, message));
    return result;
  endfunction

  // 功能：对可能为空的下游 status 做安全成功判断。
  // 输入/输出及副作用：value 只读。
  // 失败/边界：value 为 null 返回 0；仅 RDMA_SC_OK 视为成功。
  static function automatic bit status_is_ok(rdma_status value);
    return value != null && value.ok();
  endfunction

  // 功能：复制 queue/function handle 的值，避免 UVM clone 在异常路径触发 fatal。
  // 输入/输出及副作用：source 输入；copy 先置 null，成功发布独立副本。
  // 失败/边界：source 为空是合法空引用；factory 分配失败返回 RESOURCE_EXHAUSTED，不发布半成品。
  static function automatic rdma_status clone_handle_value_nonfatal(
    rdma_handle source, output rdma_handle copy
  );
    rdma_handle candidate;
    uvm_object raw_candidate;

    copy = null;
    if (source == null)
      return make_runtime_status(RDMA_SC_OK, "");
    raw_candidate = factory_create_object_nonfatal(
      rdma_handle::get_type(), "nonfatal_handle_copy");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "handle copy allocation failed");
    candidate.kind = source.kind;
    candidate.function_uid = source.function_uid;
    candidate.object_id = source.object_id;
    candidate.generation = source.generation;
    copy = candidate;
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：复制 producer/consumer cursor 的 index/wrap。
  // 输入/输出及副作用：source 输入；copy 先置 null，成功为独立快照。
  // 失败/边界：source 为空返回成功空值；分配失败返回 RESOURCE_EXHAUSTED。
  static function automatic rdma_status clone_cursor_value_nonfatal(
    rdma_queue_cursor_snapshot source,
    output rdma_queue_cursor_snapshot copy
  );
    rdma_queue_cursor_snapshot candidate;
    uvm_object raw_candidate;

    copy = null;
    if (source == null)
      return make_runtime_status(RDMA_SC_OK, "");
    raw_candidate = factory_create_object_nonfatal(
      rdma_queue_cursor_snapshot::get_type(), "nonfatal_cursor_copy");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "cursor copy allocation failed");
    candidate.index = source.index;
    candidate.wrap = source.wrap;
    copy = candidate;
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：深复制硬件镜像的 metadata、bytes 与 field_summary，使 recovery 可重放原始内容。
  // 输入/输出及副作用：source 输入；copy 先置 null；复用模型元数据复制，清空再重填 bytes/summary，
  //  不调用 source.clone/copy。
  // 失败/边界：source 为空返回成功空值；factory 空/错型返回 RESOURCE_EXHAUSTED；不检测 factory alias。
  static function automatic rdma_status clone_image_value_nonfatal(
    rdma_hw_image source, output rdma_hw_image copy
  );
    rdma_hw_image candidate;
    uvm_object raw_candidate;

    copy = null;
    if (source == null)
      return make_runtime_status(RDMA_SC_OK, "");
    raw_candidate = factory_create_object_nonfatal(
      rdma_hw_image::get_type(), "nonfatal_image_copy");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "image copy allocation failed");
    rdma_hw_image::copy_metadata_noalloc(source, candidate);
    candidate.bytes.delete();
    foreach (source.bytes[i]) candidate.bytes.push_back(source.bytes[i]);
    candidate.field_summary.delete();
    foreach (source.field_summary[i]) candidate.field_summary.push_back(source.field_summary[i]);
    copy = candidate;
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：复制 rdma_status 的完整诊断字段（错误码、硬件上下文、retry 语义）。
  // 输入/输出及副作用：source 输入；copy 先置 null，经无分配字段复制发布快照，不调用 clone/do_copy。
  // 失败/边界：source 为空返回成功空值；分配失败返回 RESOURCE_EXHAUSTED。
  static function automatic rdma_status clone_status_value_nonfatal(
    rdma_status source, output rdma_status copy
  );
    rdma_status candidate;
    uvm_object raw_candidate;

    copy = null;
    if (source == null)
      return make_runtime_status(RDMA_SC_OK, "");
    raw_candidate = factory_create_object_nonfatal(
      rdma_status::get_type(), "nonfatal_status_copy");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "status copy allocation failed");
    void'(rdma_status::copy_fields_noalloc(source, candidate));
    copy = candidate;
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：为已校验的 host WQE ledger entry 建立 detached 值副本，供 CQ poll 在 consumer 副作用前预物化。
  // 输入/输出及副作用：source 输入；copy 先置 null；复制 slot 标量、request_snapshot、image 与
  //  completion_status，不改 source。
  // 失败/边界：source 为空、factory 返回 null/错类型或嵌套复制失败时返回非成功且 copy=null，调用方须丢弃整个 candidate。
  static function automatic rdma_status clone_slot_value_nonfatal(
    rdma_queue_slot_ledger_entry source,
    output rdma_queue_slot_ledger_entry copy
  );
    rdma_queue_slot_ledger_entry candidate;
    rdma_status status;
    uvm_object raw_candidate;

    copy = null;
    if (source == null)
      return make_runtime_status(RDMA_SC_INVALID_STATE,
                                 "release range contains a null slot");
    raw_candidate = factory_create_object_nonfatal(
      rdma_queue_slot_ledger_entry::get_type(), "release_range_slot_copy");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "release range slot allocation failed");
    status = clone_request_value_nonfatal(source.request_snapshot,
                                          candidate.request_snapshot);
    if (!status_is_ok(status))
      return status == null ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "release range request copy returned null status") :
        status;
    status = clone_image_value_nonfatal(source.image, candidate.image);
    if (!status_is_ok(status))
      return status == null ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "release range image copy returned null status") :
        status;
    status = clone_status_value_nonfatal(source.completion_status,
                                         candidate.completion_status);
    if (!status_is_ok(status))
      return status == null ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "release range status copy returned null status") :
        status;
    candidate.posted = source.posted;
    candidate.consumed = source.consumed;
    candidate.signaled = source.signaled;
    candidate.wr_id = source.wr_id;
    candidate.index = source.index;
    candidate.wrap = source.wrap;
    copy = candidate;
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：复制 UD address-vector 的固定数组与全部路由字段。
  // 输入/输出及副作用：source 输入；copy 先置 null，成功后与 source 隔离。
  // 失败/边界：source 为空返回成功空值；分配失败返回 RESOURCE_EXHAUSTED，不发布半成品。
  static function automatic rdma_status clone_address_vector_value_nonfatal(
    rdma_address_vector source, output rdma_address_vector copy
  );
    rdma_address_vector candidate;
    uvm_object raw_candidate;

    copy = null;
    if (source == null)
      return make_runtime_status(RDMA_SC_OK, "");
    raw_candidate = factory_create_object_nonfatal(
      rdma_address_vector::get_type(), "nonfatal_address_vector_copy");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "address vector copy allocation failed");
    candidate.source_address_index = source.source_address_index;
    candidate.source_vport = source.source_vport;
    candidate.destination_vport = source.destination_vport;
    candidate.destination_port = source.destination_port;
    candidate.destination_mac = source.destination_mac;
    foreach (candidate.destination_ip[i])
      candidate.destination_ip[i] = source.destination_ip[i];
    candidate.ipv6 = source.ipv6;
    candidate.vlan_enable = source.vlan_enable;
    candidate.cfi = source.cfi;
    candidate.lag_enable = source.lag_enable;
    candidate.tunnel_enable = source.tunnel_enable;
    candidate.forwarding_enable = source.forwarding_enable;
    candidate.vlan_id = source.vlan_id;
    candidate.traffic_class = source.traffic_class;
    candidate.flow_label = source.flow_label;
    candidate.hop_limit = source.hop_limit;
    candidate.udp_source_port = source.udp_source_port;
    candidate.\priority = source.\priority ;
    candidate.multicast = source.multicast;
    candidate.forwarding_mode = source.forwarding_mode;
    copy = candidate;
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：复制 send/receive 请求的标量、owner、目标句柄、地址向量与 nullable SGE 列表。
  // 输入/输出及副作用：source 输入；copy 先置 null；深复制对象图，不改源；source.owner 为空时保留 factory
  //  candidate 的既有 owner 字段。
  // 失败/边界：source 为空返回成功空值；非 send/recv 返回 INVALID_ARGUMENT；factory 空/错型或嵌套 clone
  //  失败返回相应错误且 copy=null。
  static function automatic rdma_status clone_request_value_nonfatal(
    rdma_semantic_request source, output rdma_semantic_request copy
  );
    rdma_semantic_request candidate;
    rdma_post_send_req post_source;
    rdma_post_recv_req recv_source;
    rdma_post_send_req post_candidate;
    rdma_post_recv_req recv_candidate;
    rdma_handle handle_copy;
    rdma_function_handle owner_copy;
    rdma_address_vector address_vector_copy;
    rdma_sge sge_copy;
    rdma_status status;
    uvm_object raw_candidate;

    copy = null;
    if (source == null)
      return make_runtime_status(RDMA_SC_OK, "");

    if ($cast(post_source, source)) begin
      raw_candidate = factory_create_object_nonfatal(
        rdma_post_send_req::get_type(), "nonfatal_post_request_copy");
      if (raw_candidate == null || !$cast(post_candidate, raw_candidate))
        return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "post request copy allocation failed");
      candidate = post_candidate;
    end
    else if ($cast(recv_source, source)) begin
      raw_candidate = factory_create_object_nonfatal(
        rdma_post_recv_req::get_type(), "nonfatal_recv_request_copy");
      if (raw_candidate == null || !$cast(recv_candidate, raw_candidate))
        return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "receive request copy allocation failed");
      candidate = recv_candidate;
    end else begin
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "unsupported semantic request subclass");
    end

    candidate.request_id = source.request_id;
    candidate.correlation_id = source.correlation_id;
    candidate.expected_status_code = source.expected_status_code;
    candidate.timeout_policy = source.timeout_policy;
    candidate.timeout_value = source.timeout_value;
    if (source.owner != null) begin
      raw_candidate = factory_create_object_nonfatal(
        rdma_function_handle::get_type(), "nonfatal_owner_copy");
      if (raw_candidate == null || !$cast(owner_copy, raw_candidate))
        return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "request owner copy allocation failed");
      owner_copy.kind = source.owner.kind;
      owner_copy.function_uid = source.owner.function_uid;
      owner_copy.object_id = source.owner.object_id;
      owner_copy.generation = source.owner.generation;
      candidate.owner = owner_copy;
    end

    if (post_source != null) begin
      status = clone_handle_value_nonfatal(post_source.qp_h, handle_copy);
      if (!status_is_ok(status))
        return (status == null) ?
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "post QP handle copy returned null status") : status;
      post_candidate.qp_h = handle_copy;
      post_candidate.wr_id = post_source.wr_id;
      post_candidate.transport = post_source.transport;
      post_candidate.opcode = post_source.opcode;
      post_candidate.inline_data = post_source.inline_data;
      post_candidate.payload = post_source.payload;
      post_candidate.signaled = post_source.signaled;
      post_candidate.solicited = post_source.solicited;
      post_candidate.immediate_data = post_source.immediate_data;
      post_candidate.remote_addr = post_source.remote_addr;
      post_candidate.rkey = post_source.rkey;
      post_candidate.remote_access_valid = post_source.remote_access_valid;
      post_candidate.rkey_valid = post_source.rkey_valid;
      post_candidate.destination_qpn = post_source.destination_qpn;
      post_candidate.qkey = post_source.qkey;
      post_candidate.invalidate_rkey = post_source.invalidate_rkey;
      status = clone_handle_value_nonfatal(post_source.completion_qp_h,
                                           handle_copy);
      if (!status_is_ok(status))
        return (status == null) ?
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "completion QP copy returned null status") : status;
      post_candidate.completion_qp_h = handle_copy;
      status = clone_handle_value_nonfatal(post_source.mr_h, handle_copy);
      if (!status_is_ok(status))
        return (status == null) ?
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "MR handle copy returned null status") : status;
      post_candidate.mr_h = handle_copy;
      status = clone_handle_value_nonfatal(post_source.mw_h, handle_copy);
      if (!status_is_ok(status))
        return (status == null) ?
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "MW handle copy returned null status") : status;
      post_candidate.mw_h = handle_copy;
      status = clone_handle_value_nonfatal(post_source.authority_h, handle_copy);
      if (!status_is_ok(status))
        return (status == null) ?
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "authority handle copy returned null status") : status;
      post_candidate.authority_h = handle_copy;
      status = clone_address_vector_value_nonfatal(post_source.address_vector,
                                                   address_vector_copy);
      if (!status_is_ok(status))
        return (status == null) ?
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "address vector copy returned null status") : status;
      post_candidate.address_vector = address_vector_copy;
      post_candidate.fence = post_source.fence;
      post_candidate.address_vector_id = post_source.address_vector_id;
      post_candidate.address_vector_valid = post_source.address_vector_valid;
      post_candidate.sgb_iova = post_source.sgb_iova;
      post_candidate.compare_value = post_source.compare_value;
      post_candidate.swap_add_value = post_source.swap_add_value;
      post_candidate.sges.delete();
      foreach (post_source.sges[i]) begin
        if (post_source.sges[i] == null) begin post_candidate.sges.push_back(null); end
        else begin
          raw_candidate = factory_create_object_nonfatal(
            rdma_sge::get_type(), $sformatf("nonfatal_sge_%0d", i));
          if (raw_candidate == null || !$cast(sge_copy, raw_candidate))
            return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                       "SGE copy allocation failed");
          sge_copy.iova = post_source.sges[i].iova;
          sge_copy.length = post_source.sges[i].length;
          sge_copy.lkey = post_source.sges[i].lkey;
          post_candidate.sges.push_back(sge_copy);
        end
      end
    end
    else if (recv_source != null) begin
      status = clone_handle_value_nonfatal(recv_source.target_h, handle_copy);
      if (!status_is_ok(status))
        return (status == null) ?
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "receive target copy returned null status") : status;
      recv_candidate.target_h = handle_copy;
      status = clone_handle_value_nonfatal(recv_source.completion_qp_h,
                                           handle_copy);
      if (!status_is_ok(status))
        return (status == null) ?
          make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                              "receive completion QP copy returned null status") : status;
      recv_candidate.completion_qp_h = handle_copy;
      recv_candidate.wr_id = recv_source.wr_id;
      recv_candidate.sges.delete();
      foreach (recv_source.sges[i]) begin
        if (recv_source.sges[i] == null) begin
          recv_candidate.sges.push_back(null);
        end else begin
          raw_candidate = factory_create_object_nonfatal(
            rdma_sge::get_type(), $sformatf("nonfatal_recv_sge_%0d", i));
          if (raw_candidate == null || !$cast(sge_copy, raw_candidate))
            return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                       "receive SGE copy allocation failed");
          sge_copy.iova = recv_source.sges[i].iova;
          sge_copy.length = recv_source.sges[i].length;
          sge_copy.lkey = recv_source.sges[i].lkey;
          recv_candidate.sges.push_back(sge_copy);
        end
      end
    end
    copy = candidate;
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：完整比较两个 nullable handle 的 identity。
  // 输入/输出及副作用：lhs/rhs 只读，比较 kind/function_uid/object_id/generation。
  // 失败/边界：两个 null 相等；仅一侧 null 或任一字段不等返回 0。
  static function automatic bit handle_value_equal(rdma_handle lhs, rdma_handle rhs);
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    return lhs.kind == rhs.kind &&
           lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id &&
           lhs.generation == rhs.generation;
  endfunction

  // 功能：把 target handle 与 copy_ring_state 在 source lock 内冻结的四元 identity 值比较。
  // 输入/输出及副作用：candidate 为非拥有句柄；expected_* 为 source 的 detached 标量快照；只读，返回 bit。
  // 失败/边界：candidate 为空返回 0；调用方须先拒绝 source 为空并保证快照来自有效 queue_h；任一字段不等返回 0，
  //  避免释放 source lock 后重读可变对象。
  static function automatic bit handle_value_matches_snapshot(
    rdma_handle candidate,
    rdma_resource_kind_e expected_kind,
    longint unsigned expected_function_uid,
    int unsigned expected_object_id,
    int unsigned expected_generation
  );
    if (candidate == null)
      return 1'b0;
    return candidate.kind == expected_kind &&
           candidate.function_uid == expected_function_uid &&
           candidate.object_id == expected_object_id &&
           candidate.generation == expected_generation;
  endfunction

  // 功能：比较两组已取得的 route/epoch 值快照，供 ring copy 与 prepared recovery 共用。
  // 输入/输出及副作用：lhs/rhs 的 route key 与 reset epoch 只读；返回 bit。
  // 失败/边界：route 或 epoch 不等返回 0；不检查 valid-bit、格式或 reset freshness，由调用方先处理。
  static function automatic bit same_route_epoch_value(
    rdma_route_key_t lhs_route,
    rdma_reset_epoch_t lhs_epoch,
    rdma_route_key_t rhs_route,
    rdma_reset_epoch_t rhs_epoch
  );
    return lhs_route == rhs_route && lhs_epoch == rhs_epoch;
  endfunction

  // 功能：比较 recovery image 的 metadata、目标地址、bytes 与 field_summary。
  // 输入/输出及副作用：lhs/rhs 只读；返回 bit。
  // 失败/边界：两个 null 相等；长度或任一 metadata/byte/summary 不同返回 0。
  static function automatic bit image_value_equal(rdma_hw_image lhs, rdma_hw_image rhs);
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    if (lhs.length != rhs.length || lhs.alignment != rhs.alignment ||
        lhs.endian != rhs.endian || lhs.image_kind != rhs.image_kind ||
        lhs.hardware_version != rhs.hardware_version ||
        lhs.function_generation != rhs.function_generation ||
        lhs.write_target_kind != rhs.write_target_kind ||
        lhs.backing_target != rhs.backing_target ||
        lhs.hmc_target != rhs.hmc_target || lhs.bar_target != rhs.bar_target ||
        lhs.bytes.size() != rhs.bytes.size() ||
        lhs.field_summary.size() != rhs.field_summary.size())
      return 1'b0;
    foreach (lhs.bytes[i])
      if (lhs.bytes[i] != rhs.bytes[i])
        return 1'b0;
    foreach (lhs.field_summary[i])
      if (lhs.field_summary[i] != rhs.field_summary[i])
        return 1'b0;
    return 1'b1;
  endfunction

  // 功能：比较 failure_status 的分类、硬件上下文、transaction identity、严重度、retry 属性与文本。
  // 输入/输出及副作用：lhs/rhs 只读；返回 bit。
  // 失败/边界：两个 null 相等；仅一侧 null 或任一字段不等返回 0。
  static function automatic bit status_value_equal(rdma_status lhs, rdma_status rhs);
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    return lhs.category == rhs.category && lhs.code == rhs.code &&
           lhs.hardware_code == rhs.hardware_code &&
           lhs.hardware_code_valid == rhs.hardware_code_valid &&
           lhs.source_engine == rhs.source_engine &&
           lhs.function_uid == rhs.function_uid &&
           lhs.generation == rhs.generation &&
           lhs.resource_id == rhs.resource_id &&
           lhs.command_id == rhs.command_id && lhs.wr_id == rhs.wr_id &&
           lhs.severity == rhs.severity && lhs.retryable == rhs.retryable &&
           lhs.message == rhs.message;
  endfunction

  // 功能：比较 post-send 请求内的完整 UD address-vector（含 destination_ip 数组与转发/封装属性）。
  // 输入/输出及副作用：lhs/rhs 只读；返回 bit。
  // 失败/边界：两个 null 相等；仅一侧 null 或任一字段不等返回 0。
  static function automatic bit address_vector_value_equal(
    rdma_address_vector lhs, rdma_address_vector rhs
  );
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    if (lhs.source_address_index != rhs.source_address_index ||
        lhs.source_vport != rhs.source_vport ||
        lhs.destination_vport != rhs.destination_vport ||
        lhs.destination_port != rhs.destination_port ||
        lhs.destination_mac != rhs.destination_mac || lhs.ipv6 != rhs.ipv6 ||
        lhs.vlan_enable != rhs.vlan_enable || lhs.cfi != rhs.cfi ||
        lhs.lag_enable != rhs.lag_enable ||
        lhs.tunnel_enable != rhs.tunnel_enable ||
        lhs.forwarding_enable != rhs.forwarding_enable ||
        lhs.vlan_id != rhs.vlan_id ||
        lhs.traffic_class != rhs.traffic_class ||
        lhs.flow_label != rhs.flow_label || lhs.hop_limit != rhs.hop_limit ||
        lhs.udp_source_port != rhs.udp_source_port ||
        lhs.\priority  != rhs.\priority  ||
        lhs.multicast != rhs.multicast ||
        lhs.forwarding_mode != rhs.forwarding_mode)
      return 1'b0;
    foreach (lhs.destination_ip[i])
      if (lhs.destination_ip[i] != rhs.destination_ip[i])
        return 1'b0;
    return 1'b1;
  endfunction

  // 功能：按实际 post-send/post-recv 子类比较 request（semantic base、owner、handle、address-vector、payload、SGE）。
  // 输入/输出及副作用：lhs/rhs 只读；返回 bit。
  // 失败/边界：两个 null 相等；子类不同/不支持、嵌套 null 形态或值字段不同返回 0。
  static function automatic bit request_value_equal(
    rdma_semantic_request lhs, rdma_semantic_request rhs
  );
    rdma_post_send_req lhs_send;
    rdma_post_send_req rhs_send;
    rdma_post_recv_req lhs_recv;
    rdma_post_recv_req rhs_recv;

    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    if (lhs.request_id != rhs.request_id ||
        lhs.correlation_id != rhs.correlation_id ||
        !handle_value_equal(lhs.owner, rhs.owner) ||
        lhs.expected_status_code != rhs.expected_status_code ||
        lhs.timeout_policy != rhs.timeout_policy ||
        lhs.timeout_value != rhs.timeout_value)
      return 1'b0;

    if ($cast(lhs_send, lhs)) begin
      if (!$cast(rhs_send, rhs))
        return 1'b0;
      if (!handle_value_equal(lhs_send.qp_h, rhs_send.qp_h) ||
          lhs_send.wr_id != rhs_send.wr_id ||
          lhs_send.transport != rhs_send.transport ||
          lhs_send.opcode != rhs_send.opcode ||
          lhs_send.inline_data != rhs_send.inline_data ||
          lhs_send.payload.size() != rhs_send.payload.size() ||
          lhs_send.signaled != rhs_send.signaled ||
          lhs_send.solicited != rhs_send.solicited ||
          lhs_send.immediate_data != rhs_send.immediate_data ||
          lhs_send.remote_addr != rhs_send.remote_addr ||
          lhs_send.rkey != rhs_send.rkey ||
          lhs_send.remote_access_valid != rhs_send.remote_access_valid ||
          lhs_send.rkey_valid != rhs_send.rkey_valid ||
          lhs_send.destination_qpn != rhs_send.destination_qpn ||
          lhs_send.qkey != rhs_send.qkey ||
          lhs_send.invalidate_rkey != rhs_send.invalidate_rkey ||
          !handle_value_equal(lhs_send.completion_qp_h,
                              rhs_send.completion_qp_h) ||
          !handle_value_equal(lhs_send.mr_h, rhs_send.mr_h) ||
          !handle_value_equal(lhs_send.mw_h, rhs_send.mw_h) ||
          !handle_value_equal(lhs_send.authority_h, rhs_send.authority_h) ||
          lhs_send.address_vector_id != rhs_send.address_vector_id ||
          !address_vector_value_equal(lhs_send.address_vector,
                                      rhs_send.address_vector) ||
          lhs_send.fence != rhs_send.fence ||
          lhs_send.address_vector_valid != rhs_send.address_vector_valid ||
          lhs_send.sgb_iova != rhs_send.sgb_iova ||
          lhs_send.compare_value != rhs_send.compare_value ||
          lhs_send.swap_add_value != rhs_send.swap_add_value ||
          lhs_send.sges.size() != rhs_send.sges.size())
        return 1'b0;
      foreach (lhs_send.payload[i])
        if (lhs_send.payload[i] != rhs_send.payload[i])
          return 1'b0;
      foreach (lhs_send.sges[i]) begin
        if (lhs_send.sges[i] == null || rhs_send.sges[i] == null) begin
          if (!(lhs_send.sges[i] == null && rhs_send.sges[i] == null))
            return 1'b0;
        end else if (lhs_send.sges[i].iova != rhs_send.sges[i].iova ||
                     lhs_send.sges[i].length != rhs_send.sges[i].length ||
                     lhs_send.sges[i].lkey != rhs_send.sges[i].lkey) begin
          return 1'b0;
        end
      end
      return 1'b1;
    end

    if ($cast(lhs_recv, lhs)) begin
      if (!$cast(rhs_recv, rhs))
        return 1'b0;
      if (!handle_value_equal(lhs_recv.target_h, rhs_recv.target_h) ||
          !handle_value_equal(lhs_recv.completion_qp_h,
                              rhs_recv.completion_qp_h) ||
          lhs_recv.wr_id != rhs_recv.wr_id ||
          lhs_recv.sges.size() != rhs_recv.sges.size())
        return 1'b0;
      foreach (lhs_recv.sges[i]) begin
        if (lhs_recv.sges[i] == null || rhs_recv.sges[i] == null) begin
          if (!(lhs_recv.sges[i] == null && rhs_recv.sges[i] == null))
            return 1'b0;
        end else if (lhs_recv.sges[i].iova != rhs_recv.sges[i].iova ||
                     lhs_recv.sges[i].length != rhs_recv.sges[i].length ||
                     lhs_recv.sges[i].lkey != rhs_recv.sges[i].lkey) begin
          return 1'b0;
        end
      end
      return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：比较 prepared 重入时不可借用的完整 transaction evidence；MMIO enum 与阶段位由后续单调 merge 单独处理。
  // 输入/输出及副作用：lhs/rhs 只读 pending 及嵌套值对象；返回 bit，不投影 MMIO、不分配、不改 pending。
  // 失败/边界：pending 或必需 cursor/next 为空返回 0；identity/image/status/request/WR/completion/
  //  routed-QP/route-epoch 不等返回 0；不比较可推进的 MMIO/完成阶段位，不能据此单独授权 merge。
  static function automatic bit pending_immutable_evidence_equal(
    rdma_queue_pending_operation lhs,
    rdma_queue_pending_operation rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return handle_value_equal(lhs.queue_h, rhs.queue_h) &&
           lhs.kind == rhs.kind && lhs.producer == rhs.producer &&
           lhs.device_producer == rhs.device_producer &&
           lhs.entry_offset == rhs.entry_offset &&
           lhs.entry_size == rhs.entry_size &&
           lhs.cursor != null && rhs.cursor != null &&
           cursor_equal(lhs.cursor.index, lhs.cursor.wrap,
                        rhs.cursor.index, rhs.cursor.wrap) &&
           lhs.next_cursor != null && rhs.next_cursor != null &&
           cursor_equal(lhs.next_cursor.index, lhs.next_cursor.wrap,
                        rhs.next_cursor.index, rhs.next_cursor.wrap) &&
           image_value_equal(lhs.image, rhs.image) &&
           status_value_equal(lhs.failure_status, rhs.failure_status) &&
           request_value_equal(lhs.request_snapshot, rhs.request_snapshot) &&
           lhs.wr_id == rhs.wr_id && lhs.signaled == rhs.signaled &&
           lhs.completion_index == rhs.completion_index &&
           lhs.completion_wrap == rhs.completion_wrap &&
           lhs.completion_target_valid == rhs.completion_target_valid &&
           lhs.completion_wq_kind == rhs.completion_wq_kind &&
           handle_value_equal(lhs.routed_qp_h, rhs.routed_qp_h) &&
           lhs.consumer_shadow_required == rhs.consumer_shadow_required &&
           lhs.consumer_shadow_urc == rhs.consumer_shadow_urc &&
           lhs.consumer_shadow_offset == rhs.consumer_shadow_offset &&
           lhs.consumer_shadow_length == rhs.consumer_shadow_length &&
           lhs.consumer_shadow_value == rhs.consumer_shadow_value &&
           lhs.route == rhs.route && lhs.route_valid == rhs.route_valid &&
           lhs.reset_epoch == rhs.reset_epoch &&
           lhs.epoch_valid == rhs.epoch_valid;
  endfunction

  // 功能：先构造整份 pending evidence，嵌套 clone 全部成功后才交付。
  // 输入/输出及副作用：source 输入；copy 先置 null；复制嵌套值、route/epoch 与阶段位，不提交 runtime 状态。
  // 失败/边界：source 空或 device-producer 缺 queue/cursor/next/image 返回 INVALID_ARGUMENT；factory 空/错型返回
  //   RESOURCE_EXHAUSTED；嵌套错误透传且 copy=null。
  static function automatic rdma_status clone_pending_value(
    rdma_queue_pending_operation source,
    output rdma_queue_pending_operation copy
  );
    rdma_queue_pending_operation candidate;
    rdma_status status;
    uvm_object raw_candidate;

    copy = null;
    if (source == null)
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "pending source is null");
    if (source.device_producer &&
        (source.queue_h == null || source.cursor == null ||
         source.next_cursor == null || source.image == null))
      return make_runtime_status(RDMA_SC_INVALID_ARGUMENT,
                                 "device pending lacks required evidence");
    raw_candidate = factory_create_object_nonfatal(
      rdma_queue_pending_operation::get_type(), "nonfatal_pending_copy");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "pending copy allocation failed");

    status = clone_handle_value_nonfatal(source.queue_h, candidate.queue_h);
    if (!status_is_ok(status))
      return (status == null) ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "pending queue copy returned null status") : status;
    status = clone_cursor_value_nonfatal(source.cursor, candidate.cursor);
    if (!status_is_ok(status))
      return (status == null) ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "pending cursor copy returned null status") : status;
    status = clone_cursor_value_nonfatal(source.next_cursor, candidate.next_cursor);
    if (!status_is_ok(status))
      return (status == null) ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "pending next cursor copy returned null status") : status;
    status = clone_cursor_value_nonfatal(source.committed_consumer_cursor,
                                         candidate.committed_consumer_cursor);
    if (!status_is_ok(status))
      return (status == null) ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "pending committed cursor copy returned null status") : status;
    status = clone_image_value_nonfatal(source.image, candidate.image);
    if (!status_is_ok(status))
      return (status == null) ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "pending image copy returned null status") : status;
    status = clone_status_value_nonfatal(source.failure_status,
                                         candidate.failure_status);
    if (!status_is_ok(status))
      return (status == null) ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "pending failure status copy returned null status") : status;
    status = clone_request_value_nonfatal(source.request_snapshot,
                                          candidate.request_snapshot);
    if (!status_is_ok(status))
      return (status == null) ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "pending request copy returned null status") : status;
    status = clone_handle_value_nonfatal(source.routed_qp_h,
                                         candidate.routed_qp_h);
    if (!status_is_ok(status))
      return (status == null) ?
        make_runtime_status(RDMA_SC_RESOURCE_EXHAUSTED,
                            "pending routed QP copy returned null status") : status;
    candidate.kind = source.kind;
    candidate.producer = source.producer;
    candidate.device_producer = source.device_producer;
    candidate.device_write_attempted = source.device_write_attempted;
    candidate.consumer_committed = source.consumer_committed;
    candidate.cq_consumer_committed = source.cq_consumer_committed;
    candidate.completion_released = source.completion_released;
    candidate.consumer_doorbell_succeeded = source.consumer_doorbell_succeeded;
    candidate.consumer_shadow_required = source.consumer_shadow_required;
    candidate.consumer_shadow_urc = source.consumer_shadow_urc;
    candidate.consumer_shadow_attempted = source.consumer_shadow_attempted;
    candidate.consumer_shadow_published = source.consumer_shadow_published;
    candidate.consumer_shadow_offset = source.consumer_shadow_offset;
    candidate.consumer_shadow_length = source.consumer_shadow_length;
    candidate.consumer_shadow_value = source.consumer_shadow_value;
    candidate.entry_offset = source.entry_offset;
    candidate.wr_id = source.wr_id;
    candidate.signaled = source.signaled;
    candidate.completion_index = source.completion_index;
    candidate.completion_wrap = source.completion_wrap;
    candidate.completion_target_valid = source.completion_target_valid;
    candidate.completion_wq_kind = source.completion_wq_kind;
    candidate.mmio_maybe_submitted = source.mmio_maybe_submitted;
    candidate.known_no_mmio = source.known_no_mmio;
    candidate.mmio_evidence = source.mmio_evidence;
    candidate.entry_size = source.entry_size;
    candidate.route = source.route;
    candidate.route_valid = source.route_valid;
    candidate.reset_epoch = source.reset_epoch;
    candidate.epoch_valid = source.epoch_valid;
    copy = candidate;
    return make_runtime_status(RDMA_SC_OK, "");
  endfunction

  // 功能：把两组 index/wrap 作为完整 ring cursor 比较。
  // 输入/输出及副作用：a/aw 与 b/bw 只读；返回 bit。
  // 失败/边界：不等返回 0；不验证 index<depth。
  static function automatic bit cursor_equal(
    int unsigned a,
    bit aw,
    int unsigned b,
    bit bw
  );
    return a == b && aw == bw;
  endfunction
endclass
