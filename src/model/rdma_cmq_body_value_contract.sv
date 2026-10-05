// 目录/层次：模型层 model/rdma_cmq_body_value_contract.sv。
// 职责：集中 CMQ 核心 body 的 exact runtime shape、稳定值键与对象图节点枚举契约。
// 依赖：依赖 queue/context model 与 UVM object wrapper identity；不依赖 codec 或 profile。
// 所有权与生命周期：helper 无状态且只读输入；append 只向调用方拥有的 queue 追加非拥有引用，
//   不清空、不去重，不延长对象生命周期。

// 设计说明：本层只承载 model 可见的形状与值投影；需要 profile 扩展判断的 same_body_value
// 与 body_graph_detached 留在 engine/core 层，避免 model 反向依赖 codec。

// 功能：按 kind、function_uid、object_id、generation 顺序生成稳定 handle 值键。
// 输入/输出及副作用：handle 只读；返回格式化 string。
// 失败/边界：handle 为 null 时返回 "<null-handle>"；不校验 X/Z，不补默认值。
function automatic string rdma_cmq_handle_value_key(input rdma_handle handle);
  if (handle == null)
    return "<null-handle>";
  return $sformatf("%0d:%016h:%08h:%08h", handle.kind,
                   handle.function_uid, handle.object_id,
                   handle.generation);
endfunction

// 功能：用 UVM registry wrapper identity 判断 value 是否恰为 expected_type（排除 subtype）。
// 输入/输出及副作用：value/expected_type 只读；返回 bit。
// 失败/边界：value、expected_type 或实际 wrapper 为 null 返回 0；可 cast 的 subtype 也返回 0。
function automatic bit rdma_cmq_has_exact_object_type(
  input uvm_object value,
  input uvm_object_wrapper expected_type
);
  uvm_object_wrapper actual_type;

  if (value == null || expected_type == null)
    return 1'b0;
  actual_type = value.get_object_type();
  return actual_type != null && actual_type == expected_type;
endfunction

// 功能：判断 optional value 为空，或其 wrapper identity 恰为 expected_type。
// 输入/输出及副作用：value/expected_type 只读；返回 bit。
// 失败/边界：value 为 null 恒返回 1（含 expected_type 也为 null）；非空 value 按 exact-type 判定。
function automatic bit rdma_cmq_has_optional_exact_object_type(
  input uvm_object value,
  input uvm_object_wrapper expected_type
);
  return value == null || rdma_cmq_has_exact_object_type(value, expected_type);
endfunction

// 功能：确认七类核心 CMQ body 及其 required/optional 嵌套对象都是规定的精确 runtime 类型。
// 输入/输出及副作用：body 只读；检查 SQE/QPC/CQC/MRT/SRQC/CEQC/AEQC 外壳，返回 bit。
// 失败/边界：null、未知/subtype body、缺失 required 对象、嵌套 subtype 错误或 URC queues 非精确类型
//   返回 0；RC/UD transport 与 optional target/SRQ/CEQ 的原接受语义不变。
function automatic bit rdma_cmq_core_body_shell_is_exact(
  input rdma_hw_model body
);
  rdma_cmq_sqe_model sqe;
  rdma_qpc_model qpc;
  rdma_qpc_urc_ext urc_ext;
  rdma_cqc_model cqc;
  rdma_mrt_model mrt;
  rdma_srqc_model srqc;
  rdma_ceqc_model ceqc;
  rdma_aeqc_model aeqc;

  if (body == null)
    return 1'b0;
  if (rdma_cmq_has_exact_object_type(body, rdma_cmq_sqe_model::get_type())) begin
    if (!$cast(sqe, body)) begin
      return 1'b0;
    end
    return rdma_cmq_has_exact_object_type(
             sqe.function_h, rdma_function_handle::get_type()
           ) &&
           rdma_cmq_has_optional_exact_object_type(
             sqe.target_h, rdma_handle::get_type()
           );
  end
  if (rdma_cmq_has_exact_object_type(body, rdma_qpc_model::get_type())) begin
    if (!$cast(qpc, body)) begin
      return 1'b0;
    end
    if (!rdma_cmq_has_exact_object_type(qpc.qp_h, rdma_handle::get_type()) ||
        !rdma_cmq_has_exact_object_type(qpc.pd_h, rdma_handle::get_type()) ||
        !rdma_cmq_has_exact_object_type(qpc.send_cq_h, rdma_handle::get_type()) ||
        !rdma_cmq_has_exact_object_type(qpc.recv_cq_h, rdma_handle::get_type()) ||
        !rdma_cmq_has_optional_exact_object_type(
          qpc.srq_h, rdma_handle::get_type()
        ) ||
        !rdma_cmq_has_exact_object_type(
          qpc.address_vector, rdma_address_vector::get_type()
        ) ||
        !rdma_cmq_has_exact_object_type(
          qpc.behavior, rdma_qpc_behavior::get_type()
        ))
      return 1'b0;
    if (rdma_cmq_has_exact_object_type(qpc.transport_ext,
                              rdma_qpc_rc_ext::get_type()) ||
        rdma_cmq_has_exact_object_type(qpc.transport_ext,
                              rdma_qpc_ud_ext::get_type()))
      return 1'b1;
    if (!rdma_cmq_has_exact_object_type(qpc.transport_ext,
                               rdma_qpc_urc_ext::get_type()) ||
        !$cast(urc_ext, qpc.transport_ext))
      return 1'b0;
    return rdma_cmq_has_exact_object_type(
      urc_ext.queues, rdma_urc_queue_config::get_type()
    );
  end
  if (rdma_cmq_has_exact_object_type(body, rdma_cqc_model::get_type())) begin
    if (!$cast(cqc, body)) begin
      return 1'b0;
    end
    return rdma_cmq_has_exact_object_type(cqc.cq_h, rdma_handle::get_type()) &&
           rdma_cmq_has_optional_exact_object_type(
             cqc.ceq_h, rdma_handle::get_type()
           ) &&
           rdma_cmq_has_exact_object_type(
             cqc.page_layout, rdma_page_table_layout::get_type()
           ) &&
           rdma_cmq_has_exact_object_type(
             cqc.producer, rdma_ring_position::get_type()
           ) &&
           rdma_cmq_has_exact_object_type(
             cqc.consumer, rdma_ring_position::get_type()
           );
  end
  if (rdma_cmq_has_exact_object_type(body, rdma_mrt_model::get_type())) begin
    if (!$cast(mrt, body)) begin
      return 1'b0;
    end
    return rdma_cmq_has_exact_object_type(mrt.mr_h, rdma_handle::get_type()) &&
           rdma_cmq_has_exact_object_type(mrt.pd_h, rdma_handle::get_type()) &&
           rdma_cmq_has_exact_object_type(
             mrt.page_layout, rdma_mr_page_layout::get_type()
           );
  end
  if (rdma_cmq_has_exact_object_type(body, rdma_srqc_model::get_type())) begin
    if (!$cast(srqc, body)) begin
      return 1'b0;
    end
    return rdma_cmq_has_exact_object_type(srqc.srq_h, rdma_handle::get_type()) &&
           rdma_cmq_has_exact_object_type(srqc.pd_h, rdma_handle::get_type()) &&
           rdma_cmq_has_exact_object_type(
             srqc.producer, rdma_ring_position::get_type()
           );
  end
  if (rdma_cmq_has_exact_object_type(body, rdma_ceqc_model::get_type())) begin
    if (!$cast(ceqc, body)) begin
      return 1'b0;
    end
    return rdma_cmq_has_exact_object_type(ceqc.ceq_h, rdma_handle::get_type()) &&
           rdma_cmq_has_exact_object_type(
             ceqc.page_layout, rdma_page_table_layout::get_type()
           ) &&
           rdma_cmq_has_exact_object_type(
             ceqc.producer, rdma_ring_position::get_type()
           ) &&
           rdma_cmq_has_exact_object_type(
             ceqc.consumer, rdma_ring_position::get_type()
           );
  end
  if (rdma_cmq_has_exact_object_type(body, rdma_aeqc_model::get_type())) begin
    if (!$cast(aeqc, body)) begin
      return 1'b0;
    end
    return rdma_cmq_has_exact_object_type(aeqc.aeq_h, rdma_handle::get_type()) &&
           rdma_cmq_has_exact_object_type(
             aeqc.page_layout, rdma_page_table_layout::get_type()
           ) &&
           rdma_cmq_has_exact_object_type(
             aeqc.producer, rdma_ring_position::get_type()
           ) &&
           rdma_cmq_has_exact_object_type(
             aeqc.consumer, rdma_ring_position::get_type()
           );
  end
  return 1'b0;
endfunction

// 功能：按固定字段顺序为 handle、ring、page、AV、URC queue、MR page 与 QPC 扩展生成稳定值键。
// 输入/输出及副作用：value 只读；返回 string，不修改 nested model。
// 失败/边界：null 返回 "<null-object>"，未知或非精确 subtype 返回空串；X/Z 只参与格式化；
//   URC 扩展递归生成 queues 键，不新增校验。
function automatic string rdma_cmq_nested_value_key(input uvm_object value);
  rdma_handle handle;
  rdma_ring_position ring;
  rdma_page_table_layout page_layout;
  rdma_address_vector address_vector;
  rdma_urc_queue_config queues;
  rdma_mr_page_layout mr_page_layout;
  rdma_qpc_behavior behavior;
  rdma_qpc_rc_ext rc_ext;
  rdma_qpc_ud_ext ud_ext;
  rdma_qpc_urc_ext urc_ext;
  string result;

  if (value == null)
    return "<null-object>";
  if (rdma_cmq_has_exact_object_type(value, rdma_handle::get_type()) &&
      $cast(handle, value))
    return {"handle:", rdma_cmq_handle_value_key(handle)};
  if (rdma_cmq_has_exact_object_type(value, rdma_ring_position::get_type()) &&
      $cast(ring, value))
    return $sformatf("ring:%0d:%0b", ring.index, ring.wrap);
  if (rdma_cmq_has_exact_object_type(value, rdma_page_table_layout::get_type()) &&
      $cast(page_layout, value))
    return $sformatf("page:%0d:%016h:%016h:%0b:%016h:%0b",
                     page_layout.mode, page_layout.sd_base.value,
                     page_layout.current_base.value,
                     page_layout.current_valid,
                     page_layout.next_base.value,
                     page_layout.next_valid);
  if (rdma_cmq_has_exact_object_type(value, rdma_address_vector::get_type()) &&
      $cast(address_vector, value)) begin
    result = $sformatf(
      "av:%0d:%0d:%0d:%0d:%012h:%0b:%0b:%0b:%0b:%0b:%0b:%03h:%02h:%05h:%02h:%04h",
      address_vector.source_address_index, address_vector.source_vport,
      address_vector.destination_vport,
      address_vector.destination_port,
      address_vector.destination_mac, address_vector.ipv6,
      address_vector.vlan_enable, address_vector.cfi,
      address_vector.lag_enable, address_vector.tunnel_enable,
      address_vector.forwarding_enable, address_vector.vlan_id,
      address_vector.traffic_class, address_vector.flow_label,
      address_vector.hop_limit, address_vector.udp_source_port
    );
    foreach (address_vector.destination_ip[i])
      result = {result,
                $sformatf(":%02h", address_vector.destination_ip[i])};
    return result;
  end
  if (rdma_cmq_has_exact_object_type(value, rdma_urc_queue_config::get_type()) &&
      $cast(queues, value))
    return $sformatf(
      "urcq:%016h:%016h:%016h:%0d:%0d:%0d:%0d:%0d:%0d",
      queues.rsq_backing.value, queues.rdsq_backing.value,
      queues.dsq_backing.value, queues.rsq_depth, queues.rdsq_depth,
      queues.rdsq_fetch_count, queues.dsq_fetch_count,
      queues.rq_sequence_threshold_entries,
      queues.sq_completion_threshold_entries
    );
  if (rdma_cmq_has_exact_object_type(value, rdma_mr_page_layout::get_type()) &&
      $cast(mr_page_layout, value))
    return $sformatf(
      "mrpage:%0d:%0d:%016h:%016h:%0d:%0d:%0b:%0b:%0b:%0d:%0d",
      mr_page_layout.pbl_mode, mr_page_layout.host_page_size,
      mr_page_layout.pba0.value, mr_page_layout.pba1.value,
      mr_page_layout.first_pbl_index, mr_page_layout.address_mode,
      mr_page_layout.odp, mr_page_layout.invalidate_enable,
      mr_page_layout.payload_vf_enable,
      mr_page_layout.payload_vf_id, mr_page_layout.mr_serial
    );
  if (rdma_cmq_has_exact_object_type(value, rdma_qpc_behavior::get_type()) &&
      $cast(behavior, value))
    return $sformatf("behavior:%0d:%0b:%0b:%0b:%0b:%0b:%0d",
                     behavior.transport_version,
                     behavior.migration_enable,
                     behavior.tx_endian_swap, behavior.rx_endian_swap,
                     behavior.read_after_write_fence,
                     behavior.atomic_after_atomic_fence,
                     behavior.\priority );
  if (rdma_cmq_has_exact_object_type(value, rdma_qpc_rc_ext::get_type()) &&
      $cast(rc_ext, value))
    return $sformatf("rc:%06h:%06h:%06h:%0d:%0d",
                     rc_ext.remote_qpn, rc_ext.send_psn,
                     rc_ext.recv_psn, rc_ext.retry_count,
                     rc_ext.rnr_retry_count);
  if (rdma_cmq_has_exact_object_type(value, rdma_qpc_ud_ext::get_type()) &&
      $cast(ud_ext, value))
    return $sformatf("ud:%08h", ud_ext.qkey);
  if (rdma_cmq_has_exact_object_type(value, rdma_qpc_urc_ext::get_type()) &&
      $cast(urc_ext, value))
    return $sformatf("urc:%06h:%06h:%06h:%06h:%06h:%s",
                     urc_ext.remote_qpn, urc_ext.rbsn, urc_ext.dbsn,
                     urc_ext.rpsn, urc_ext.dpsn,
                     rdma_cmq_nested_value_key(urc_ext.queues));
  return "";
endfunction

// 功能：按固定字段顺序为 SQE/QPC/CQC/MRT/SRQC/CEQC/AEQC 生成稳定 body 值键。
// 输入/输出及副作用：body 只读；返回 string；SQE 的 context_model 递归调用本函数。
// 失败/边界：null 返回 "<null-body>"，未知或非精确 subtype 返回空串，null context 用 "<null-context>"；
//   不做环检测，调用方不得传入循环 context graph。
function automatic string rdma_cmq_body_value_key(input rdma_hw_model body);
  rdma_cmq_sqe_model sqe;
  rdma_qpc_model qpc;
  rdma_cqc_model cqc;
  rdma_mrt_model mrt;
  rdma_srqc_model srqc;
  rdma_ceqc_model ceqc;
  rdma_aeqc_model aeqc;

  if (body == null)
    return "<null-body>";
  if (rdma_cmq_has_exact_object_type(body, rdma_cmq_sqe_model::get_type()) &&
      $cast(sqe, body))
    return $sformatf("sqe:%0d:%016h:%08h:%s:%s:%s", sqe.opcode,
                     sqe.command_id, sqe.flags,
                     rdma_cmq_handle_value_key(sqe.function_h),
                     rdma_cmq_handle_value_key(sqe.target_h),
                     (sqe.context_model == null) ? "<null-context>" :
                       rdma_cmq_body_value_key(sqe.context_model));
  if (rdma_cmq_has_exact_object_type(body, rdma_qpc_model::get_type()) &&
      $cast(qpc, body))
    return $sformatf(
      "qpc:%s:%s:%s:%s:%s:%0d:%0d:%0d:%0d:%0d:%04h:%02h:%0h:%0d:%0d:%0d:%016h:%016h:%016h:%0d:%0d:%s:%0b:%0b:%0b:%s:%s",
      rdma_cmq_handle_value_key(qpc.qp_h), rdma_cmq_handle_value_key(qpc.pd_h),
      rdma_cmq_handle_value_key(qpc.send_cq_h),
      rdma_cmq_handle_value_key(qpc.recv_cq_h), rdma_cmq_handle_value_key(qpc.srq_h),
      qpc.transport, qpc.state, qpc.host_id, qpc.vf_id,
      qpc.stat_index, qpc.pkey, qpc.qp_sequence, qpc.access,
      qpc.path_mtu_bytes, qpc.sq_depth, qpc.rq_depth,
      qpc.sq_backing.value, qpc.rq_backing.value,
      qpc.context_backing.value, qpc.sq_mode, qpc.rq_mode,
      rdma_cmq_nested_value_key(qpc.address_vector), qpc.signature_enable,
      qpc.tx_flow_control, qpc.rx_flow_control,
      rdma_cmq_nested_value_key(qpc.behavior),
      rdma_cmq_nested_value_key(qpc.transport_ext)
    );
  if (rdma_cmq_has_exact_object_type(body, rdma_cqc_model::get_type()) &&
      $cast(cqc, body))
    return $sformatf(
      "cqc:%s:%s:%0d:%0d:%0d:%0d:%s:%s:%s:%0b:%0b:%0h:%0h:%0h:%016h",
      rdma_cmq_handle_value_key(cqc.cq_h), rdma_cmq_handle_value_key(cqc.ceq_h),
      cqc.state, cqc.depth, cqc.cqe_size_bytes, cqc.threshold,
      rdma_cmq_nested_value_key(cqc.page_layout),
      rdma_cmq_nested_value_key(cqc.producer), rdma_cmq_nested_value_key(cqc.consumer),
      cqc.urc_enable, cqc.load_ci_done, cqc.last_arm_sequence,
      cqc.arm_sequence, cqc.arm_state, cqc.shadow_backing.value
    );
  if (rdma_cmq_has_exact_object_type(body, rdma_mrt_model::get_type()) &&
      $cast(mrt, body))
    return $sformatf(
      "mrt:%s:%s:%0d:%016h:%016h:%08h:%08h:%0h:%0h:%s",
      rdma_cmq_handle_value_key(mrt.mr_h), rdma_cmq_handle_value_key(mrt.pd_h),
      mrt.state, mrt.iova.value, mrt.length, mrt.lkey, mrt.rkey,
      mrt.access, mrt.object_type, rdma_cmq_nested_value_key(mrt.page_layout)
    );
  if (rdma_cmq_has_exact_object_type(body, rdma_srqc_model::get_type()) &&
      $cast(srqc, body))
    return $sformatf(
      "srqc:%s:%s:%0d:%0d:%0d:%0d:%0d:%016h:%016h:%s:%0h",
      rdma_cmq_handle_value_key(srqc.srq_h), rdma_cmq_handle_value_key(srqc.pd_h),
      srqc.state, srqc.depth, srqc.load_pi_threshold,
      srqc.limit_threshold, srqc.object_mode,
      srqc.srfq_backing.value, srqc.shadow_backing.value,
      rdma_cmq_nested_value_key(srqc.producer), srqc.arm_sequence
    );
  if (rdma_cmq_has_exact_object_type(body, rdma_ceqc_model::get_type()) &&
      $cast(ceqc, body))
    return $sformatf("ceqc:%s:%0d:%0d:%0d:%s:%s:%s",
                     rdma_cmq_handle_value_key(ceqc.ceq_h), ceqc.state,
                     ceqc.depth, ceqc.vector_id,
                     rdma_cmq_nested_value_key(ceqc.page_layout),
                     rdma_cmq_nested_value_key(ceqc.producer),
                     rdma_cmq_nested_value_key(ceqc.consumer));
  if (rdma_cmq_has_exact_object_type(body, rdma_aeqc_model::get_type()) &&
      $cast(aeqc, body))
    return $sformatf("aeqc:%s:%0d:%0d:%0d:%s:%s:%s",
                     rdma_cmq_handle_value_key(aeqc.aeq_h), aeqc.state,
                     aeqc.depth, aeqc.vector_id,
                     rdma_cmq_nested_value_key(aeqc.page_layout),
                     rdma_cmq_nested_value_key(aeqc.producer),
                     rdma_cmq_nested_value_key(aeqc.consumer));
  return "";
endfunction

// 功能：向调用方拥有的 nodes queue 追加 root 与直接 nested 对象引用。
// 输入/输出及副作用：body 只读；nodes 为 ref，仅尾部追加非拥有引用，不清空或去重。
// 失败/边界：null 不追加，未知非空 body 只追加 root；SQE 不追加 context_model；QPC 的 URC queues
//   在 $cast 成功且非 null 时追加；已有前缀、alias 与重复项全部保留。
function automatic void rdma_cmq_append_body_graph_nodes(
  input rdma_hw_model body,
  ref uvm_object nodes[$]
);
  rdma_cmq_sqe_model sqe;
  rdma_qpc_model qpc;
  rdma_qpc_urc_ext urc_ext;
  rdma_cqc_model cqc;
  rdma_mrt_model mrt;
  rdma_srqc_model srqc;
  rdma_ceqc_model ceqc;
  rdma_aeqc_model aeqc;

  if (body == null)
    return;
  nodes.push_back(body);
  if (rdma_cmq_has_exact_object_type(body, rdma_cmq_sqe_model::get_type()) &&
      $cast(sqe, body)) begin
    if (sqe.function_h != null) nodes.push_back(sqe.function_h);
    if (sqe.target_h != null) nodes.push_back(sqe.target_h);
  end
  else if (rdma_cmq_has_exact_object_type(body, rdma_qpc_model::get_type()) &&
           $cast(qpc, body)) begin
    if (qpc.qp_h != null) nodes.push_back(qpc.qp_h);
    if (qpc.pd_h != null) nodes.push_back(qpc.pd_h);
    if (qpc.send_cq_h != null) nodes.push_back(qpc.send_cq_h);
    if (qpc.recv_cq_h != null) nodes.push_back(qpc.recv_cq_h);
    if (qpc.srq_h != null) nodes.push_back(qpc.srq_h);
    if (qpc.address_vector != null) nodes.push_back(qpc.address_vector);
    if (qpc.behavior != null) nodes.push_back(qpc.behavior);
    if (qpc.transport_ext != null) nodes.push_back(qpc.transport_ext);
    if ($cast(urc_ext, qpc.transport_ext) && urc_ext.queues != null)
      nodes.push_back(urc_ext.queues);
  end
  else if (rdma_cmq_has_exact_object_type(body, rdma_cqc_model::get_type()) &&
           $cast(cqc, body)) begin
    if (cqc.cq_h != null) nodes.push_back(cqc.cq_h);
    if (cqc.ceq_h != null) nodes.push_back(cqc.ceq_h);
    if (cqc.page_layout != null) nodes.push_back(cqc.page_layout);
    if (cqc.producer != null) nodes.push_back(cqc.producer);
    if (cqc.consumer != null) nodes.push_back(cqc.consumer);
  end
  else if (rdma_cmq_has_exact_object_type(body, rdma_mrt_model::get_type()) &&
           $cast(mrt, body)) begin
    if (mrt.mr_h != null) nodes.push_back(mrt.mr_h);
    if (mrt.pd_h != null) nodes.push_back(mrt.pd_h);
    if (mrt.page_layout != null) nodes.push_back(mrt.page_layout);
  end
  else if (rdma_cmq_has_exact_object_type(body, rdma_srqc_model::get_type()) &&
           $cast(srqc, body)) begin
    if (srqc.srq_h != null) nodes.push_back(srqc.srq_h);
    if (srqc.pd_h != null) nodes.push_back(srqc.pd_h);
    if (srqc.producer != null) nodes.push_back(srqc.producer);
  end
  else if (rdma_cmq_has_exact_object_type(body, rdma_ceqc_model::get_type()) &&
           $cast(ceqc, body)) begin
    if (ceqc.ceq_h != null) nodes.push_back(ceqc.ceq_h);
    if (ceqc.page_layout != null) nodes.push_back(ceqc.page_layout);
    if (ceqc.producer != null) nodes.push_back(ceqc.producer);
    if (ceqc.consumer != null) nodes.push_back(ceqc.consumer);
  end
  else if (rdma_cmq_has_exact_object_type(body, rdma_aeqc_model::get_type()) &&
           $cast(aeqc, body)) begin
    if (aeqc.aeq_h != null) nodes.push_back(aeqc.aeq_h);
    if (aeqc.page_layout != null) nodes.push_back(aeqc.page_layout);
    if (aeqc.producer != null) nodes.push_back(aeqc.producer);
    if (aeqc.consumer != null) nodes.push_back(aeqc.consumer);
  end
endfunction
