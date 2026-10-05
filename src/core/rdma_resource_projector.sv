// 目录：核心执行层 core/rdma_resource_projector.sv。
// 职责：集中构造 resource/recovery 的 detached 快照及其身份、mapping 值比较。
// 依赖：types/model/adapter 值契约、UVM 类型与 resource allocator 的 kind 分类。
// 所有权与生命周期：不持有实例状态、账本、锁或 manager 引用；新载体由调用方持有，
//   外部 backing 和 opaque completion/release authority 仍归 adapter 管理。
// 设计：普通载体 direct-new；owned/recovery mapping、slot token 与 programmed CQC
//   保留各自 checked clone 契约，不能统一为虚拟深拷贝或丢弃 opaque authority。
//   无状态不等于纯函数：clone、authority、validate、identity 和 status factory 可重入。
//   caller 必须在锁外调用，并在提交时复核 epoch/source；此层不替代生命周期准入。

// 将对象图复制与事务写入分离，使 manager 只拥有状态和提交规则；static automatic
// 方法的局部变量按调用隔离，不引入第二份 mutable owner 或共享的临时快照。
class rdma_resource_projector;

  // 功能：复制资源 handle 的四个身份字段；Function kind 使用具体 Function handle 类型。
  // 输入/输出及副作用：source 为借用输入，copy_label 命名新对象，result 输出独立 handle；不调用 source.clone。
  // 失败/边界：source 为空返回成功/null；Function kind 无法转换为 Function handle 时返回 INVALID_ARGUMENT。
  static function automatic rdma_status project_handle_value(
    rdma_handle source,
    string copy_label,
    output rdma_handle result
  );
    rdma_function_handle source_function;
    rdma_function_handle result_function;

    result = null;
    if (source == null)
      return rdma_status::success();
    if (source.kind == RDMA_RESOURCE_FUNCTION) begin
      if (!$cast(source_function, source))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          {copy_label, " Function handle is structurally incompatible"}
        );
      result_function = new({copy_label, "_function_handle"});
      result = result_function;
    end
    else begin
      result = new({copy_label, "_handle"});
    end
    result.kind = source.kind;
    result.function_uid = source.function_uid;
    result.object_id = source.object_id;
    result.generation = source.generation;
    return rdma_status::success();
  endfunction

  // 功能：将 Function handle 身份复制到新建的内建对象，隔离调用方可变字段。
  // 输入/输出及副作用：读取 source 的 kind/function_uid/object_id/generation，copy_label 命名，result 输出副本。
  // 失败/边界：source 为空返回成功/null；不验证 kind、当前代际或 Function authority，准入由调用方负责。
  static function automatic rdma_status project_function_handle_value(
    rdma_function_handle source,
    string copy_label,
    output rdma_function_handle result
  );
    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_function_handle"});
    result.kind = source.kind;
    result.function_uid = source.function_uid;
    result.object_id = source.object_id;
    result.generation = source.generation;
    return rdma_status::success();
  endfunction

  // 功能：为借用 DMA mapping 复制公开字段及独立 Function/owner handle，保留 route/reset epoch。
  // 输入/输出及副作用：source 为输入，copy_label 命名，result 输出内建 mapping；不复制 opaque release capability。
  // 失败/边界：source 为空返回成功/null；handle 投影失败清空 result 并传播 status，不判断映射有效性。
  static function automatic rdma_status project_mapping_value(
    rdma_dma_mapping source,
    string copy_label,
    output rdma_dma_mapping result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_mapping"});
    status = project_function_handle_value(
      source.function_h, {copy_label, "_function"}, result.function_h
    );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    status = project_handle_value(source.owner_h, {copy_label, "_owner"},
                                  result.owner_h);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.requester_bdf = source.requester_bdf;
    result.pasid_valid = source.pasid_valid;
    result.pasid = source.pasid;
    result.dma_domain_valid = source.dma_domain_valid;
    result.dma_domain_id = source.dma_domain_id;
    // Route 与 reset epoch 是 mapping authority 的一部分。若 detached
    // projection 丢失这两个字段，CQ resize recovery 无法证明旧 backing
    // 仍属于原 Host/Function，也不能安全执行 opaque cleanup。
    result.route = source.route;
    result.route_valid = source.route_valid;
    result.reset_epoch = source.reset_epoch;
    result.epoch_valid = source.epoch_valid;
    result.backing_addr = source.backing_addr;
    result.iova = source.iova;
    result.size = source.size;
    result.direction = source.direction;
    result.permissions = source.permissions;
    result.state = source.state;
    return rdma_status::success();
  endfunction

  // 功能：为 mapping/HMC 比较复用四字段 handle 身份等值规则。
  // 输入/输出及副作用：只读 lhs/rhs 并返回 same_handle_instance 的结果，不查询 adapter 或修改对象。
  // 失败/边界：双 null 相等，单 null 不等；不证明对象隔离、authority 或 generation 新鲜度。
  static function automatic bit same_mapping_handle_value(
    rdma_handle lhs,
    rdma_handle rhs
  );
    return same_handle_instance(lhs, rhs);
  endfunction

  // 功能：比较 DMA 释放身份、地址范围、权限及完整 route/reset epoch，刻意不比较 state。
  // 输入/输出及副作用：只读 lhs/rhs 的 Function/owner、requester/DMA、route/epoch 和地址字段，返回等值 bit。
  // 失败/边界：双 null 相等；单 null 或任一字段不同返回 0；两侧相同的无效标志也可相等，不等价于准入。
  static function automatic bit same_mapping_release_fields(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    return same_mapping_handle_value(lhs.function_h, rhs.function_h) &&
           lhs.requester_bdf == rhs.requester_bdf &&
           lhs.pasid_valid == rhs.pasid_valid &&
           lhs.pasid == rhs.pasid &&
           lhs.dma_domain_valid == rhs.dma_domain_valid &&
           lhs.dma_domain_id == rhs.dma_domain_id &&
           lhs.route_valid == rhs.route_valid &&
           lhs.route.host_topology_key == rhs.route.host_topology_key &&
           lhs.route.root_id == rhs.route.root_id &&
           lhs.route.segment == rhs.route.segment &&
           rdma_bdf_same(lhs.route.bdf, rhs.route.bdf) &&
           lhs.epoch_valid == rhs.epoch_valid &&
           lhs.reset_epoch == rhs.reset_epoch &&
           lhs.backing_addr.value == rhs.backing_addr.value &&
           lhs.iova.value == rhs.iova.value &&
           lhs.size == rhs.size &&
           lhs.direction == rhs.direction &&
           lhs.permissions == rhs.permissions &&
           same_mapping_handle_value(lhs.owner_h, rhs.owner_h);
  endfunction

  // 功能：在释放字段等值的基础上继续比较 mapping.state，区分 ACTIVE/RELEASED 快照。
  // 输入/输出及副作用：lhs/rhs 为借用 mapping，返回 release 字段与 state 的联合比较结果，无完成查询。
  // 失败/边界：双 null 相等，单 null 不等；类型和 opaque authority 不参与值比较。
  static function automatic bit same_mapping_value(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return same_mapping_release_fields(lhs, rhs) &&
           lhs.state == rhs.state;
  endfunction

  // 功能：检查两个 mapping 没有共享非空 Function/owner handle 引用。
  // 输入/输出及副作用：只读 lhs/rhs 的嵌套对象引用，返回隔离 bit；不比较 handle 的字段值。
  // 失败/边界：任一 mapping 为空返回 0；某一嵌套 handle 为空允许通过，等值性须另行验证。
  static function automatic bit mapping_handles_detached(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return (lhs.function_h == null || rhs.function_h == null ||
            lhs.function_h != rhs.function_h) &&
           (lhs.owner_h == null || rhs.owner_h == null ||
            lhs.owner_h != rhs.owner_h);
  endfunction

  // 功能：验证一次 mapping hook 后的类型、公开值和嵌套 handle 隔离仍与冻结值一致。
  // 输入/输出及副作用：current 为 hook 后对象，saved 为值快照，expected_type 为注册类型；调用 get_object_type。
  // 失败/边界：对象空/别名、类型空/变化、字段变化或嵌套别名返回 0；不证明 opaque release authority。
  static function automatic bit mapping_hook_value_intact(
    rdma_dma_mapping current,
    rdma_dma_mapping saved,
    uvm_object_wrapper expected_type
  );
    uvm_object_wrapper current_type;

    if (current == null || saved == null || current == saved ||
        expected_type == null)
      return 1'b0;
    current_type = current.get_object_type();
    return current_type != null && current_type == expected_type &&
           same_mapping_value(current, saved) &&
           mapping_handles_detached(current, saved);
  endfunction

  // 功能：核对 source、clone 与 authority snapshot 三方对象图未因 hook 发生值或别名污染。
  // 输入/输出及副作用：source/result 对照 saved_value/source_type；
  //   authority_snapshot 对照 saved_authority/authority_type。
  // 失败/边界：三方对象或 handle 共享、类型和值变化返回 0；只调用类型查询，不执行释放或账本写入。
  static function automatic bit owned_mapping_hook_graph_intact(
    rdma_dma_mapping source,
    rdma_dma_mapping result,
    rdma_dma_mapping saved_value,
    uvm_object_wrapper source_type,
    rdma_dma_mapping authority_snapshot,
    rdma_dma_mapping saved_authority,
    uvm_object_wrapper authority_type
  );
    return source != result && source != authority_snapshot &&
           result != authority_snapshot &&
           mapping_hook_value_intact(source, saved_value, source_type) &&
           mapping_hook_value_intact(result, saved_value, source_type) &&
           mapping_hook_value_intact(authority_snapshot, saved_authority,
                                     authority_type) &&
           mapping_handles_detached(source, result) &&
           mapping_handles_detached(source, authority_snapshot) &&
           mapping_handles_detached(result, authority_snapshot);
  endfunction

  // 功能：保留 owned mapping 的具体 release capability，并在 snapshot、clone 和双侧 authority hook 后校验对象图。
  // 输入/输出及副作用：source 为 adapter 拥有的 mapping，copy_label 命名检查快照，result 输出同类型 detached clone；不释放资源。
  // 失败/边界：空源、未注册/基类类型、无效 authority、clone 失败、字段/类型/别名变化返回 INVALID_ARGUMENT；
  //   值投影失败传播 status；所有失败清空 result，hook/factory 可同步重入，调用方须复核 epoch/source。
  static function automatic rdma_status clone_owned_mapping_value(
    rdma_dma_mapping source,
    string copy_label,
    output rdma_dma_mapping result
  );
    rdma_dma_mapping saved_value;
    rdma_dma_mapping authority_snapshot;
    rdma_dma_mapping saved_authority;
    rdma_status status;
    uvm_object cloned_object;
    uvm_object_wrapper source_type;
    uvm_object_wrapper result_type;
    uvm_object_wrapper authority_type;

    result = null;
    if (source == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping is null"}
      );
    status = project_mapping_value(source, {copy_label, "_saved"},
                                   saved_value);
    if (!status.ok())
      return status;
    source_type = source.get_object_type();
    if (source_type == null ||
        source_type == rdma_dma_mapping::get_type())
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping type is not a registered subtype"}
      );
    status = source.snapshot_release_authority(authority_snapshot);
    if (status == null || !status.ok() || authority_snapshot == null ||
        authority_snapshot == source ||
        !same_mapping_value(source, saved_value)) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping authority snapshot is unsupported or invalid"}
      );
    end
    authority_type = authority_snapshot.get_object_type();
    status = project_mapping_value(
      authority_snapshot, {copy_label, "_saved_authority"}, saved_authority
    );
    if (status == null || !status.ok() || authority_type == null ||
        authority_type != source_type ||
        !mapping_hook_value_intact(authority_snapshot, saved_authority,
                                   authority_type) ||
        !mapping_handles_detached(source, authority_snapshot)) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping authority snapshot changed value, type, or aliases"}
      );
    end
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(result, cloned_object) ||
        result == source) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping clone contract failed"}
      );
    end
    result_type = result.get_object_type();
    if (result_type == null || result_type != source_type ||
        !owned_mapping_hook_graph_intact(
          source, result, saved_value, source_type,
          authority_snapshot, saved_authority, authority_type
        )) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping clone changed type, value, or aliases"}
      );
    end
    status = source.release_authority_status(authority_snapshot);
    if (status == null || !status.ok() ||
        !owned_mapping_hook_graph_intact(
          source, result, saved_value, source_type,
          authority_snapshot, saved_authority, authority_type
        )) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping source authority hook changed value, authority, or aliases"}
      );
    end
    status = result.release_authority_status(authority_snapshot);
    if (status == null || !status.ok() ||
        !owned_mapping_hook_graph_intact(
          source, result, saved_value, source_type,
          authority_snapshot, saved_authority, authority_type
        )) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping result authority hook changed value, authority, or aliases"}
      );
    end
    return rdma_status::success();
  endfunction

  // 功能：按 ownership 复制 backing 引用：owned 保留受验证 release capability，borrowed 仅投影值，再校验新引用。
  // 输入/输出及副作用：source/copy_label 为输入，
  //   result 输出含 ownership/release_complete 的独立 backing reference；validate 可回调。
  // 失败/边界：空源成功/null；mapping 或 validate 失败清空 result 并传播状态，null validation status 返回 INVALID_STATE。
  static function automatic rdma_status project_backing_ref_value(
    rdma_backing_ref source,
    string copy_label,
    output rdma_backing_ref result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_backing_ref"});
    result.mapping = null;
    if (source.ownership == RDMA_OWNERSHIP_CONTROL_PLANE)
      status = clone_owned_mapping_value(
        source.mapping, {copy_label, "_mapping"}, result.mapping
      );
    else
      status = project_mapping_value(
        source.mapping, {copy_label, "_mapping"}, result.mapping
      );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.ownership = source.ownership;
    result.release_complete = source.release_complete;
    status = result.validate();
    if (status == null) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {copy_label, " backing validation returned null"}
      );
    end
    if (!status.ok())
      result = null;
    return status;
  endfunction

  // 功能：复制 HMC owner、对象类别、地址、大小和 PBL 索引/释放元数据。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出带独立 Function owner 的 HMC reference；不分配 HMC。
  // 失败/边界：空源成功/null；owner 投影失败清空 result 并传播 status，不验证 index 或释放完成证明。
  static function automatic rdma_status project_hmc_ref_value(
    rdma_hmc_ref source,
    string copy_label,
    output rdma_hmc_ref result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_hmc_ref"});
    status = project_function_handle_value(
      source.owner, {copy_label, "_owner"}, result.owner
    );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.object_kind = source.object_kind;
    result.address = source.address;
    result.size = source.size;
    result.first_pbl_index = source.first_pbl_index;
    result.index_valid = source.index_valid;
    result.ownership = source.ownership;
    result.release_complete = source.release_complete;
    return rdma_status::success();
  endfunction

  // 功能：复制冻结 BAR 的编号、基址、大小和 enabled 标志，不重新推导 topology。
  // 输入/输出及副作用：source 为 BAR metadata，copy_label 命名，result 输出独立 BAR 对象，无 PCIe 写入。
  // 失败/边界：source 为空返回 INVALID_ARGUMENT/null；非空值原样复制，不检查地址对齐或窗口合法性。
  static function automatic rdma_status project_bar_value(
    rdma_bar_info source,
    string copy_label,
    output rdma_bar_info result
  );
    result = null;
    if (source == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " BAR metadata is null"}
      );
    result = new({copy_label, "_bar"});
    result.bar_id = source.bar_id;
    result.base = source.base;
    result.size = source.size;
    result.enabled = source.enabled;
    return rdma_status::success();
  endfunction

  // 功能：复制 PCIe 身份、MSE/BME 与全部 BAR 对象，隔离外部可变 metadata。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出独立 PCIe identity；只消费已有 BDF/PF/VF 信息。
  // 失败/边界：source 或任一 BAR 为空返回 INVALID_ARGUMENT，BAR 投影失败清空 result；不配置真实 PCIe。
  static function automatic rdma_status project_pcie_value(
    rdma_pcie_identity source,
    string copy_label,
    output rdma_pcie_identity result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " PCIe identity is null"}
      );
    result = new({copy_label, "_pcie"});
    foreach (result.bar[i])
      result.bar[i] = null;
    result.bdf = source.bdf;
    result.parent_pf_bdf = source.parent_pf_bdf;
    result.vf_index = source.vf_index;
    result.mse = source.mse;
    result.bme = source.bme;
    foreach (source.bar[i]) begin
      status = project_bar_value(
        source.bar[i], $sformatf("%s_bar_%0d", copy_label, i),
        result.bar[i]
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
    end
    return rdma_status::success();
  endfunction

  // 功能：复制 Function binding，包括受保护 identity snapshot、PCIe、DMA/caps/vector 和 readiness 镜像。
  // 输入/输出及副作用：source/copy_label 为输入，
  //   result 输出新 binding；调用 identity snapshot/configure_identity 保留已有 authority。
  // 失败/边界：空 binding/PCIe/BAR、identity 配置或 owner 投影失败清空 result 并传播 status；
  //   不登记 binding 或刷新 generation。
  static function automatic rdma_status project_binding_value(
    rdma_function_binding source,
    string copy_label,
    output rdma_function_binding result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " Function binding is null"}
      );
    result = new({copy_label, "_binding"});
    result.pcie = null;
    result.owner_h = null;
    status = project_pcie_value(source.pcie, {copy_label, "_pcie"},
                                result.pcie);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    // Preserve the protected identity authority across value projection;
    // copying only legacy mirrors leaves the projected binding unusable.
    status = result.configure_identity(source.function_identity_snapshot());
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.queue_dma = source.queue_dma;
    result.queue_caps = source.queue_caps;
    result.interrupt_vectors = source.interrupt_vectors;
    status = project_handle_value(source.owner_h, {copy_label, "_owner"},
                                  result.owner_h);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.function_uid = source.function_uid;
    result.notify_bar_id = source.notify_bar_id;
    result.notify_base = source.notify_base;
    result.notify_size = source.notify_size;
    result.notify_table_sel = source.notify_table_sel;
    result.notify_table_index = source.notify_table_index;
    result.host_id = source.host_id;
    result.pfvf_id = source.pfvf_id;
    result.rdma_vf_id = source.rdma_vf_id;
    result.global_function_id = source.global_function_id;
    result.vsi_id = source.vsi_id;
    result.state = source.state;
    result.generation = source.generation;
    result.notify_valid = source.notify_valid;
    result.notify_ready = source.notify_ready;
    result.dmi_valid = source.dmi_valid;
    result.dmi_ready = source.dmi_ready;
    result.vft_valid = source.vft_valid;
    result.vft_ready = source.vft_ready;
    return rdma_status::success();
  endfunction

  // 功能：复制 CMQ profile/opcode/variant 选择键，供 ticket 和 recovery 保留命令身份。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出内建 opcode key，不查询 profile catalog。
  // 失败/边界：source 为空成功/null；不校验 opcode 是否受支持，合法性仍由命令准入负责。
  static function automatic rdma_status project_opcode_value(
    rdma_cmq_opcode_key source,
    string copy_label,
    output rdma_cmq_opcode_key result
  );
    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_opcode"});
    result.profile_name = source.profile_name;
    result.opcode = source.opcode;
    result.variant = source.variant;
    return rdma_status::success();
  endfunction

  // 功能：复制业务 status 的错误码、硬件码、关联身份、严重度和诊断文案。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出独立内建 status；返回值只表示复制是否完成，不是 source 的业务结果。
  // 失败/边界：source 为空成功/null；错误 status 也照值复制，不将其改成成功，不调用 source 的 clone。
  static function automatic rdma_status project_status_value(
    rdma_status source,
    string copy_label,
    output rdma_status result
  );
    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_status"});
    result.category = source.category;
    result.code = source.code;
    result.hardware_code = source.hardware_code;
    result.hardware_code_valid = source.hardware_code_valid;
    result.source_engine = source.source_engine;
    result.function_uid = source.function_uid;
    result.generation = source.generation;
    result.resource_id = source.resource_id;
    result.command_id = source.command_id;
    result.wr_id = source.wr_id;
    result.severity = source.severity;
    result.retryable = source.retryable;
    result.message = source.message;
    return rdma_status::success();
  endfunction

  // 功能：复制 CMQ ticket 的 Function/CMQ/opcode 子图及 command、slot、SQ cursor 和 deadline。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出独立 ticket；不提交命令、不等待或消费完成。
  // 失败/边界：空源成功/null；嵌套投影失败清空 result 并传播 status；过期 deadline 保留原值，不在此判超时。
  static function automatic rdma_status project_ticket_value(
    rdma_cmq_ticket source,
    string copy_label,
    output rdma_cmq_ticket result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_ticket"});
    status = project_function_handle_value(
      source.function_h, {copy_label, "_function"}, result.function_h
    );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    status = project_handle_value(source.cmq_h, {copy_label, "_cmq"},
                                  result.cmq_h);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    status = project_opcode_value(source.opcode_key, {copy_label, "_opcode"},
                                  result.opcode_key);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.command_id = source.command_id;
    result.slot_sequence = source.slot_sequence;
    result.sq_index = source.sq_index;
    result.sq_wrap = source.sq_wrap;
    result.absolute_deadline = source.absolute_deadline;
    return rdma_status::success();
  endfunction

  // 功能：复制 resource recovery 的硬件存在性、步骤、backing/HMC、错误和 queue/QP 恢复子图。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出独立 recovery record；owned mapping/token 等子图沿受检查回调复制。
  // 失败/边界：空 record 返回 INVALID_ARGUMENT；任一子图投影失败清空 result 并传播 status，不提交恢复进度或执行 cleanup。
  static function automatic rdma_status project_recovery_value(
    rdma_recovery_record source,
    string copy_label,
    output rdma_recovery_record result
  );
    rdma_backing_ref backing_copy;
    rdma_hmc_ref hmc_copy;
    rdma_status status_copy;
    rdma_status status;
    rdma_cmq_opcode_key opcode_copy;
    rdma_queue_backing_plan plan_copy;
    rdma_qp_recovery_state qp_recovery_copy;

    result = null;
    if (source == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " recovery record is null"}
      );
    result = new({copy_label, "_recovery"});
    status = project_handle_value(source.resource_h,
                                  {copy_label, "_resource"},
                                  result.resource_h);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.hardware_presence = source.hardware_presence;
    result.completed_steps = source.completed_steps;
    result.pending_steps = source.pending_steps;
    result.backing_refs.delete();
    foreach (source.backing_refs[i]) begin
      status = project_backing_ref_value(
        source.backing_refs[i], $sformatf("%s_backing_%0d", copy_label, i),
        backing_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.backing_refs.push_back(backing_copy);
    end
    result.hmc_refs.delete();
    foreach (source.hmc_refs[i]) begin
      status = project_hmc_ref_value(
        source.hmc_refs[i], $sformatf("%s_hmc_%0d", copy_label, i), hmc_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.hmc_refs.push_back(hmc_copy);
    end
    status = project_ticket_value(source.ambiguous_ticket,
                                  {copy_label, "_ticket"},
                                  result.ambiguous_ticket);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    status = project_status_value(source.primary_status,
                                  {copy_label, "_primary"},
                                  result.primary_status);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.rollback_statuses.delete();
    foreach (source.rollback_statuses[i]) begin
      status = project_status_value(
        source.rollback_statuses[i],
        $sformatf("%s_rollback_%0d", copy_label, i), status_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.rollback_statuses.push_back(status_copy);
    end
    result.queue_recovery_valid = source.queue_recovery_valid;
    result.queue_intent = source.queue_intent;
    result.ambiguous_queue_operation = source.ambiguous_queue_operation;
    result.ambiguous_role = source.ambiguous_role;
    status = project_opcode_value(source.queue_create_opcode,
                                  {copy_label, "_queue_create"},
                                  opcode_copy);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.queue_create_opcode = opcode_copy;
    status = project_opcode_value(source.queue_delete_opcode,
                                  {copy_label, "_queue_delete"},
                                  opcode_copy);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.queue_delete_opcode = opcode_copy;
    status = project_opcode_value(source.queue_query_opcode,
                                  {copy_label, "_queue_query"},
                                  opcode_copy);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.queue_query_opcode = opcode_copy;
    status = project_queue_plan_value(source.queue_plan,
                                      {copy_label, "_queue_plan"}, plan_copy);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.queue_plan = plan_copy;
    result.qp_recovery_valid = source.qp_recovery_valid;
    status = project_qp_recovery_value(
      source.qp_recovery, {copy_label, "_qp_recovery"}, qp_recovery_copy
    );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.qp_recovery = qp_recovery_copy;
    return rdma_status::success();
  endfunction

  // 功能：向已创建的资源副本填充 handle/owner、状态、HMC 地址、backing、依赖和 outstanding IDs。
  // 输入/输出及副作用：source/copy_label 为输入；result 是调用方提供的非空目标引用，原地更新其基础字段和数组。
  // 失败/边界：source/result 须非空且目标独立；子图失败立即传播 status，目标可能部分填充，调用方须丢弃，不能发布半成品。
  static function automatic rdma_status project_resource_base_fields(
    rdma_resource source,
    string copy_label,
    rdma_resource result
  );
    rdma_backing_ref backing_copy;
    rdma_hmc_ref hmc_copy;
    rdma_handle dependency_copy;
    rdma_status status;

    status = project_handle_value(source.handle, {copy_label, "_handle"},
                                  result.handle);
    if (!status.ok())
      return status;
    status = project_function_handle_value(
      source.owner, {copy_label, "_owner"}, result.owner
    );
    if (!status.ok())
      return status;
    result.state = source.state;
    result.hmc_fvm_addr = source.hmc_fvm_addr;
    result.hmc_fvm_addr_valid = source.hmc_fvm_addr_valid;
    result.backing_refs.delete();
    foreach (source.backing_refs[i]) begin
      status = project_backing_ref_value(
        source.backing_refs[i], $sformatf("%s_backing_%0d", copy_label, i),
        backing_copy
      );
      if (!status.ok())
        return status;
      result.backing_refs.push_back(backing_copy);
    end
    result.hmc_refs.delete();
    foreach (source.hmc_refs[i]) begin
      status = project_hmc_ref_value(
        source.hmc_refs[i], $sformatf("%s_hmc_%0d", copy_label, i), hmc_copy
      );
      if (!status.ok())
        return status;
      result.hmc_refs.push_back(hmc_copy);
    end
    result.dependencies.delete();
    foreach (source.dependencies[i]) begin
      status = project_handle_value(
        source.dependencies[i],
        $sformatf("%s_dependency_%0d", copy_label, i), dependency_copy
      );
      if (!status.ok())
        return status;
      result.dependencies.push_back(dependency_copy);
    end
    result.outstanding_ids = source.outstanding_ids;
    return rdma_status::success();
  endfunction

  // 功能：复制 queue 页的角色、逻辑/映射偏移和 IOVA，并投影借用 mapping。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出独立 DMA page reference；不申请或映射页。
  // 失败/边界：空源成功/null；mapping 投影失败清空 result；不校验 page 几何或把 borrowed mapping 转成 owned。
  static function automatic rdma_status project_queue_page_value(
    rdma_queue_dma_page_ref source,
    string copy_label,
    output rdma_queue_dma_page_ref result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_page"});
    result.role = source.role;
    result.mapping_offset = source.mapping_offset;
    result.logical_page_offset = source.logical_page_offset;
    result.page_iova = source.page_iova;
    status = project_mapping_value(source.mapping,
                                   {copy_label, "_mapping"},
                                   result.mapping);
    if (!status.ok())
      result = null;
    return status;
  endfunction

  // 功能：复制 queue ring 几何、初始 polarity 及按原顺序排列的 DMA page 子图。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出独立 ring/pages；深度与 page_count 保留原值。
  // 失败/边界：空源成功/null；任一页投影失败清空 result；不校验深度、计数或页布局一致性。
  static function automatic rdma_status project_queue_ring_value(
    rdma_queue_ring_layout source,
    string copy_label,
    output rdma_queue_ring_layout result
  );
    rdma_queue_dma_page_ref page_copy;
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_ring"});
    result.role = source.role;
    result.entry_size_bytes = source.entry_size_bytes;
    result.depth = source.depth;
    result.logical_bytes = source.logical_bytes;
    result.storage_bytes = source.storage_bytes;
    result.page_count = source.page_count;
    result.initial_polarity = source.initial_polarity;
    foreach (source.pages[i]) begin
      status = project_queue_page_value(
        source.pages[i], $sformatf("%s_page_%0d", copy_label, i), page_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.pages.push_back(page_copy);
    end
    return rdma_status::success();
  endfunction

  // 功能：复制 queue/QP 附加 segment 的 role、ownership、偏移和长度，按所有权复制 mapping。
  // 输入/输出及副作用：source、segment_label、null_error、owned_mapping_label、borrowed_mapping_label
  //   为输入；result 输出独立 segment。
  // 失败/边界：空 source 按 null_error 返回 INVALID_ARGUMENT；mapping 失败清空 result；不额外校验几何/role，
  //   borrowed null mapping 可保留。
  static function automatic rdma_status project_backing_segment_value(
    rdma_queue_backing_segment source,
    string segment_label,
    string null_error,
    string owned_mapping_label,
    string borrowed_mapping_label,
    output rdma_queue_backing_segment result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, null_error);
    result = new(segment_label);
    result.role = source.role;
    result.ownership = source.ownership;
    result.mapping_offset = source.mapping_offset;
    result.length = source.length;
    result.logical_queue_offset = source.logical_queue_offset;
    if (result.ownership == RDMA_OWNERSHIP_CONTROL_PLANE)
      status = clone_owned_mapping_value(
        source.mapping, owned_mapping_label, result.mapping
      );
    else
      status = project_mapping_value(
        source.mapping, borrowed_mapping_label, result.mapping
      );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：复制 queue backing 主引用和附加 segments，保留 cleanup_complete 及逻辑队列偏移。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出独立引用；owned mapping 走 authority clone，
  //   borrowed mapping 只复制值。
  // 失败/边界：空主引用成功/null；空 segment 或 mapping 复制失败清空 result 并传播 status，不执行 cleanup 或推进完成标志。
  static function automatic rdma_status project_queue_backing_ref_value(
    rdma_queue_backing_ref source,
    string copy_label,
    output rdma_queue_backing_ref result
  );
    rdma_queue_backing_segment segment_copy;
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_ref"});
    result.role = source.role;
    result.ownership = source.ownership;
    result.mapping_offset = source.mapping_offset;
    result.length = source.length;
    result.logical_queue_offset = source.logical_queue_offset;
    result.cleanup_complete = source.cleanup_complete;
    if (source.ownership == RDMA_OWNERSHIP_CONTROL_PLANE)
      status = clone_owned_mapping_value(source.mapping,
                                         {copy_label, "_owned_mapping"},
                                         result.mapping);
    else
      status = project_mapping_value(source.mapping,
                                     {copy_label, "_borrowed_mapping"},
                                     result.mapping);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    foreach (source.additional_segments[i]) begin
      status = project_backing_segment_value(
        source.additional_segments[i],
        $sformatf("%s_segment_%0d", copy_label, i),
        {copy_label, " additional backing segment is null"},
        $sformatf("%s_segment_%0d_owned_mapping", copy_label, i),
        $sformatf("%s_segment_%0d_borrowed_mapping", copy_label, i),
        segment_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.additional_segments.push_back(segment_copy);
    end
    return rdma_status::success();
  endfunction

  // 功能：克隆 context slot token，要求新 token 继续借用同一个不透明 completion_authority。
  // 输入/输出及副作用：source 为 token 对象，copy_label 用于错误定位，result 输出 detached token；会调用 source_token.clone。
  // 失败/边界：空源成功/null；类型不符、缺失 authority、clone 空/别名/类型错误或 authority 改变返回 INVALID_ARGUMENT/null。
  static function automatic rdma_status project_queue_slot_token_value(
    uvm_object source,
    string copy_label,
    output uvm_object result
  );
    rdma_queue_slot_token_contract source_token;
    rdma_queue_slot_token_contract result_token;
    uvm_object cloned_object;

    result = null;
    if (source == null)
      return rdma_status::success();
    if (!$cast(source_token, source) ||
        source_token.completion_authority == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " slot token contract is invalid"}
      );
    cloned_object = source_token.clone();
    if (cloned_object == null || cloned_object == source ||
        !$cast(result_token, cloned_object) ||
        result_token.completion_authority == null ||
        result_token.completion_authority !==
          source_token.completion_authority)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " slot token clone lost opaque authority"}
      );
    result = result_token;
    return rdma_status::success();
  endfunction

  // 功能：复制 context 的 owner、slot token、HMC 及 shadow/slot 布局和释放标志。
  // 输入/输出及副作用：source/copy_label 为输入，
  //   result 输出独立 context reference；仅 token 内 completion_authority 按契约共享。
  // 失败/边界：空源成功/null；owner/token/HMC 复制失败清空 result 并传播 status；不证明 slot 当前可释放。
  static function automatic rdma_status project_queue_context_value(
    rdma_context_backing_ref source,
    string copy_label,
    output rdma_context_backing_ref result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_context"});
    status = project_function_handle_value(
      source.owner, {copy_label, "_owner"}, result.owner
    );
    if (status.ok())
      status = project_queue_slot_token_value(
        source.slot_token, {copy_label, "_token"}, result.slot_token
      );
    if (status.ok())
      status = project_hmc_ref_value(
        source.hmc_ref, {copy_label, "_hmc"}, result.hmc_ref
      );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.resource_kind = source.resource_kind;
    result.local_id = source.local_id;
    result.shadow_pointer_base = source.shadow_pointer_base;
    result.slot_length = source.slot_length;
    result.shadow_view_offset = source.shadow_view_offset;
    result.shadow_view_length = source.shadow_view_length;
    result.release_complete = source.release_complete;
    return rdma_status::success();
  endfunction

  // 功能：复制 PD flush 的角色、阶段、完成标志及 backing reference。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出独立 flush target；不发起 flush 或修改完成证据。
  // 失败/边界：空源成功/null；PD reference 投影失败清空 result 并传播 status，阶段和 role 不在此准入。
  static function automatic rdma_status project_queue_flush_target_value(
    rdma_queue_flush_target source,
    string copy_label,
    output rdma_queue_flush_target result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_flush"});
    result.role = source.role;
    result.phase = source.phase;
    result.flush_complete = source.flush_complete;
    status = project_queue_backing_ref_value(
      source.pd_ref, {copy_label, "_pd_ref"}, result.pd_ref
    );
    if (!status.ok())
      result = null;
    return status;
  endfunction

  // 功能：按 rings、refs、context、flush_targets 顺序复制 queue backing plan 的完整对象图。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出独立 plan；子引用按各自 ownership 保留 authority，不申请 backing。
  // 失败/边界：空源成功/null；任一子图失败清空 result 并传播首个 status；不校验 plan 的 role 数量或整体几何。
  static function automatic rdma_status project_queue_plan_value(
    rdma_queue_backing_plan source,
    string copy_label,
    output rdma_queue_backing_plan result
  );
    rdma_queue_ring_layout ring_copy;
    rdma_queue_backing_ref ref_copy;
    rdma_queue_flush_target flush_copy;
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_plan"});
    result.resource_kind = source.resource_kind;
    foreach (source.rings[i]) begin
      status = project_queue_ring_value(
        source.rings[i], $sformatf("%s_ring_%0d", copy_label, i), ring_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.rings.push_back(ring_copy);
    end
    foreach (source.refs[i]) begin
      status = project_queue_backing_ref_value(
        source.refs[i], $sformatf("%s_ref_%0d", copy_label, i), ref_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.refs.push_back(ref_copy);
    end
    status = project_queue_context_value(
      source.context_ref, {copy_label, "_context"}, result.context_ref
    );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    foreach (source.flush_targets[i]) begin
      status = project_queue_flush_target_value(
        source.flush_targets[i],
        $sformatf("%s_flush_%0d", copy_label, i), flush_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.flush_targets.push_back(flush_copy);
    end
    return rdma_status::success();
  endfunction

  // 功能：复制 QP ring 的角色、entry/depth、逻辑/存储字节数和 object_mode。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出独立 QP ring layout；所有几何值原样保留。
  // 失败/边界：空源成功/null；不验证 transport、depth 或对象模式组合，也不分配 SQ/RQ。
  static function automatic rdma_status project_qp_ring_value(
    rdma_qp_ring_layout source,
    string copy_label,
    output rdma_qp_ring_layout result
  );
    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_ring"});
    result.role = source.role;
    result.entry_size_bytes = source.entry_size_bytes;
    result.depth = source.depth;
    result.logical_bytes = source.logical_bytes;
    result.storage_bytes = source.storage_bytes;
    result.object_mode = source.object_mode;
    return rdma_status::success();
  endfunction

  // 功能：为失败恢复保留 mapping 的具体 clone 和 completion 查询能力，绕过正常 owned authority hooks。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出 clone；先后查询 source/result completion，保持原回调顺序。
  // 失败/边界：空源/未注册类型/clone 空或类型、值、别名、完成状态变化返回 INVALID_ARGUMENT；null 查询返回 INVALID_STATE，
  //   失败查询 status 原样传播；clone 首次别名拒绝可能留下 source 于 result，调用方必须按 status 丢弃。
  static function automatic rdma_status clone_recovery_mapping_value(
    rdma_dma_mapping source,
    string copy_label,
    output rdma_dma_mapping result
  );
    uvm_object cloned_object;
    uvm_object_wrapper source_type;
    uvm_object_wrapper result_type;
    rdma_status status;
    bit source_complete;
    bit result_complete;

    result = null;
    if (source == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " recovery mapping is null"}
      );
    source_type = source.get_object_type();
    if (source_type == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " recovery mapping type is not registered"}
      );
    status = source.release_completion_status(source_complete);
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {copy_label, " recovery completion authority query returned null"}
      ) : status;
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(result, cloned_object) ||
        result == source)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " recovery mapping clone contract failed"}
      );
    result_type = result.get_object_type();
    if (result_type == null || result_type != source_type ||
        !same_mapping_value(source, result) ||
        !mapping_handles_detached(source, result)) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " recovery mapping clone changed value, type, or aliases"}
      );
    end
    status = result.release_completion_status(result_complete);
    if (status == null || !status.ok() || source_complete != result_complete) begin
      result = null;
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {copy_label, " recovery clone completion authority changed"}
      ) : status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " recovery clone completion state changed"}
      ) : status;
    end
    return rdma_status::success();
  endfunction

  // 功能：按 recovery_only、owned、borrowed 优先级复制 QP 主 mapping，再复制角色、释放标志和附加 segments。
  // 输入/输出及副作用：source/copy_label 为输入，
  //   result 输出独立 QP backing reference；恢复 clone 不调用正常 authority hooks。
  // 失败/边界：空引用成功/null；主 mapping 或任一 segment 失败清空 result 并传播 status；附加 segment 仍按各自 ownership 处理。
  static function automatic rdma_status project_qp_backing_ref_value(
    rdma_qp_backing_ref source,
    string copy_label,
    output rdma_qp_backing_ref result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_ref"});
    if (source.recovery_only)
      status = clone_recovery_mapping_value(
        source.mapping, {copy_label, "_recovery_mapping"}, result.mapping
      );
    else if (source.ownership == RDMA_OWNERSHIP_CONTROL_PLANE)
      status = clone_owned_mapping_value(
        source.mapping, {copy_label, "_owned_mapping"}, result.mapping
      );
    else
      status = project_mapping_value(
        source.mapping, {copy_label, "_borrowed_mapping"}, result.mapping
      );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.role = source.role;
    result.ownership = source.ownership;
    result.mapping_offset = source.mapping_offset;
    result.length = source.length;
    result.cleanup_complete = source.cleanup_complete;
    result.recovery_only = source.recovery_only;
    result.additional_segments.delete();
    foreach (source.additional_segments[i]) begin
      rdma_queue_backing_segment segment;

      status = project_backing_segment_value(
        source.additional_segments[i],
        {copy_label, "_segment"},
        "QP backing segment is null",
        {copy_label, "_segment_mapping"},
        {copy_label, "_segment_mapping"},
        segment
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.additional_segments.push_back(segment);
    end
    return rdma_status::success();
  endfunction

  // 功能：复制 QP transport、SQ/RQ ring 与 backing、URC 引用、RQ source 和 context，以及 flush/cleanup 进度。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出独立 QP plan；严格保持各子图投影及回调顺序。
  // 失败/边界：空源成功/null；遇到首个投影失败停止后续子图并清空 result；不执行硬件操作或验证 transport 几何。
  static function automatic rdma_status project_qp_plan_value(
    rdma_qp_backing_plan source,
    string copy_label,
    output rdma_qp_backing_plan result
  );
    rdma_qp_backing_ref ref_copy;
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_plan"});
    result.transport = source.transport;
    result.sq_depth = source.sq_depth;
    result.rq_depth = source.rq_depth;
    result.sq_pd_flush_complete = source.sq_pd_flush_complete;
    result.rq_pd_flush_complete = source.rq_pd_flush_complete;
    result.cleanup_complete = source.cleanup_complete;
    status = project_qp_ring_value(source.sq_ring, {copy_label, "_sq"},
                                   result.sq_ring);
    if (status.ok())
      status = project_qp_ring_value(source.rq_ring, {copy_label, "_rq"},
                                     result.rq_ring);
    if (status.ok())
      status = project_qp_backing_ref_value(
        source.sq_ref, {copy_label, "_sq"}, result.sq_ref
      );
    if (status.ok())
      status = project_qp_backing_ref_value(
        source.sq_sgb_ref, {copy_label, "_sq_sgb"}, result.sq_sgb_ref
      );
    if (status.ok())
      status = project_qp_backing_ref_value(
        source.rq_ref, {copy_label, "_rq"}, result.rq_ref
      );
    if (status.ok())
      status = project_qp_backing_ref_value(
        source.sq_pd_ref, {copy_label, "_sq_pd"}, result.sq_pd_ref
      );
    if (status.ok())
      status = project_qp_backing_ref_value(
        source.rq_pd_ref, {copy_label, "_rq_pd"}, result.rq_pd_ref
      );
    if (status.ok())
      status = project_handle_value(source.rq_source_h,
                                    {copy_label, "_rq_source"},
                                    result.rq_source_h);
    if (status.ok()) begin
      result.urc_refs.delete();
      foreach (source.urc_refs[i]) begin
        status = project_qp_backing_ref_value(
          source.urc_refs[i], $sformatf("%s_urc_%0d", copy_label, i),
          ref_copy
        );
        if (!status.ok()) break;
        result.urc_refs.push_back(ref_copy);
      end
    end
    if (status.ok())
      status = project_queue_context_value(
        source.context_ref, {copy_label, "_context"}, result.context_ref
      );
    if (!status.ok())
      result = null;
    return status;
  endfunction

  // 功能：复制 QPC 地址向量中的源/目的、MAC/IP、VLAN、流量和隧道/转发参数。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出独立 AV；destination_ip 数组逐元素复制，不改变网络配置。
  // 失败/边界：空源成功/null；不判断地址、VLAN 或 IP 版本组合是否可编码。
  static function automatic rdma_status project_address_vector_value(
    rdma_address_vector source,
    string copy_label,
    output rdma_address_vector result
  );
    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_address_vector"});
    result.source_address_index = source.source_address_index;
    result.source_vport = source.source_vport;
    result.destination_vport = source.destination_vport;
    result.destination_port = source.destination_port;
    result.destination_mac = source.destination_mac;
    foreach (result.destination_ip[i])
      result.destination_ip[i] = source.destination_ip[i];
    result.ipv6 = source.ipv6;
    result.vlan_enable = source.vlan_enable;
    result.cfi = source.cfi;
    result.lag_enable = source.lag_enable;
    result.tunnel_enable = source.tunnel_enable;
    result.forwarding_enable = source.forwarding_enable;
    result.vlan_id = source.vlan_id;
    result.traffic_class = source.traffic_class;
    result.flow_label = source.flow_label;
    result.hop_limit = source.hop_limit;
    result.udp_source_port = source.udp_source_port;
    return rdma_status::success();
  endfunction

  // 功能：复制 QPC 行为位：transport version、migration、端序、fence 与 priority。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出内建 behavior 对象，不修改 QP 状态。
  // 失败/边界：空源成功/null；保留所有原始位值，不在此校验 transport 支持的行为组合。
  static function automatic rdma_status project_qpc_behavior_value(
    rdma_qpc_behavior source,
    string copy_label,
    output rdma_qpc_behavior result
  );
    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_behavior"});
    result.transport_version = source.transport_version;
    result.migration_enable = source.migration_enable;
    result.tx_endian_swap = source.tx_endian_swap;
    result.rx_endian_swap = source.rx_endian_swap;
    result.read_after_write_fence = source.read_after_write_fence;
    result.atomic_after_atomic_fence = source.atomic_after_atomic_fence;
    result.\priority = source.\priority ;
    return rdma_status::success();
  endfunction

  // 功能：按实际 RC/UD/URC 类型复制 transport 扩展；URC 额外复制 queues 配置对象。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出相应内建扩展；backing 地址为值，URC queues 对象独立。
  // 失败/边界：空源成功/null，URC queues 为空可保留；不兼容扩展类型返回 INVALID_ARGUMENT/null，不验证 transport 与扩展匹配。
  static function automatic rdma_status project_qpc_extension_value(
    rdma_qpc_transport_ext source,
    string copy_label,
    output rdma_qpc_transport_ext result
  );
    rdma_qpc_rc_ext source_rc;
    rdma_qpc_rc_ext result_rc;
    rdma_qpc_ud_ext source_ud;
    rdma_qpc_ud_ext result_ud;
    rdma_qpc_urc_ext source_urc;
    rdma_qpc_urc_ext result_urc;

    result = null;
    if (source == null)
      return rdma_status::success();
    if ($cast(source_rc, source)) begin
      result_rc = new({copy_label, "_rc"});
      result_rc.remote_qpn = source_rc.remote_qpn;
      result_rc.send_psn = source_rc.send_psn;
      result_rc.recv_psn = source_rc.recv_psn;
      result_rc.retry_count = source_rc.retry_count;
      result_rc.rnr_retry_count = source_rc.rnr_retry_count;
      result = result_rc;
    end
    else if ($cast(source_ud, source)) begin
      result_ud = new({copy_label, "_ud"});
      result_ud.qkey = source_ud.qkey;
      result_ud.destination_qpn = source_ud.destination_qpn;
      result = result_ud;
    end
    else if ($cast(source_urc, source)) begin
      result_urc = new({copy_label, "_urc"});
      result_urc.remote_qpn = source_urc.remote_qpn;
      result_urc.rbsn = source_urc.rbsn;
      result_urc.dbsn = source_urc.dbsn;
      result_urc.rpsn = source_urc.rpsn;
      result_urc.dpsn = source_urc.dpsn;
      if (source_urc.queues == null)
        result_urc.queues = null;
      else begin
        result_urc.queues = new({copy_label, "_urc_queues"});
        result_urc.queues.rsq_backing = source_urc.queues.rsq_backing;
        result_urc.queues.rdsq_backing = source_urc.queues.rdsq_backing;
        result_urc.queues.dsq_backing = source_urc.queues.dsq_backing;
        result_urc.queues.rsq_depth = source_urc.queues.rsq_depth;
        result_urc.queues.rdsq_depth = source_urc.queues.rdsq_depth;
        result_urc.queues.rdsq_fetch_count =
          source_urc.queues.rdsq_fetch_count;
        result_urc.queues.dsq_fetch_count =
          source_urc.queues.dsq_fetch_count;
        result_urc.queues.rq_sequence_threshold_entries =
          source_urc.queues.rq_sequence_threshold_entries;
        result_urc.queues.sq_completion_threshold_entries =
          source_urc.queues.sq_completion_threshold_entries;
      end
      result = result_urc;
    end
    else
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " QPC transport extension is incompatible"}
      );
    return rdma_status::success();
  endfunction

  // 功能：复制 QPC 的身份子图、transport/state、队列几何/地址及 AV、behavior 和 transport 扩展。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出独立 QPC model；不写硬件、不发布 QP 状态。
  // 失败/边界：空源成功/null；handle 或 AV/behavior/extension 失败清空 result 并传播 status；不执行 QPC 编码校验。
  static function automatic rdma_status project_qpc_value(
    rdma_qpc_model source,
    string copy_label,
    output rdma_qpc_model result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_qpc"});
    status = project_handle_value(source.qp_h, {copy_label, "_qp"},
                                  result.qp_h);
    if (status.ok())
      status = project_handle_value(source.pd_h, {copy_label, "_pd"},
                                    result.pd_h);
    if (status.ok())
      status = project_handle_value(source.send_cq_h,
                                    {copy_label, "_send_cq"},
                                    result.send_cq_h);
    if (status.ok())
      status = project_handle_value(source.recv_cq_h,
                                    {copy_label, "_recv_cq"},
                                    result.recv_cq_h);
    if (status.ok())
      status = project_handle_value(source.srq_h, {copy_label, "_srq"},
                                    result.srq_h);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.transport = source.transport;
    result.state = source.state;
    result.host_id = source.host_id;
    result.vf_id = source.vf_id;
    result.stat_index = source.stat_index;
    result.pkey = source.pkey;
    result.qp_sequence = source.qp_sequence;
    result.access = source.access;
    result.path_mtu_bytes = source.path_mtu_bytes;
    result.sq_depth = source.sq_depth;
    result.rq_depth = source.rq_depth;
    result.sq_backing = source.sq_backing;
    result.rq_backing = source.rq_backing;
    result.context_backing = source.context_backing;
    result.sq_mode = source.sq_mode;
    result.rq_mode = source.rq_mode;
    result.signature_enable = source.signature_enable;
    result.tx_flow_control = source.tx_flow_control;
    result.rx_flow_control = source.rx_flow_control;
    status = project_address_vector_value(
      source.address_vector, {copy_label, "_av"}, result.address_vector
    );
    if (status.ok())
      status = project_qpc_behavior_value(
        source.behavior, {copy_label, "_behavior"}, result.behavior
      );
    if (status.ok())
      status = project_qpc_extension_value(
        source.transport_ext, {copy_label, "_extension"},
        result.transport_ext
      );
    if (!status.ok())
      result = null;
    return status;
  endfunction

  // 功能：复制 QP 恢复意图、完成标志、前后 QPC、plan/context、staging/query mapping 与命令/ticket。
  // 输入/输出及副作用：source/copy_label 为输入，
  //   result 输出独立 recovery state；query_mapping_recovery_only 决定 query clone 契约。
  // 失败/边界：空源成功/null；staging 始终用 owned clone，query 按恢复标志选路；任一子图失败清空 result，不推进恢复。
  static function automatic rdma_status project_qp_recovery_value(
    rdma_qp_recovery_state source,
    string copy_label,
    output rdma_qp_recovery_state result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_qp_recovery"});
    result.intent = source.intent;
    result.ambiguous_operation = source.ambiguous_operation;
    result.ambiguous_role = source.ambiguous_role;
    result.role_complete = source.role_complete;
    result.has_pending_hardware_step = source.has_pending_hardware_step;
    result.query_mapping_recovery_only = source.query_mapping_recovery_only;
    result.query_presence_known = source.query_presence_known;
    result.query_presence = source.query_presence;
    result.error_modify_complete = source.error_modify_complete;
    result.delete_complete = source.delete_complete;
    status = project_qpc_value(source.prior_qpc, {copy_label, "_prior"},
                               result.prior_qpc);
    if (status.ok())
      status = project_qpc_value(source.candidate_qpc,
                                 {copy_label, "_candidate"},
                                 result.candidate_qpc);
    if (status.ok())
      status = project_qp_plan_value(source.qp_plan, {copy_label, "_plan"},
                                     result.qp_plan);
    if (status.ok())
      status = project_queue_context_value(
        source.context_ref, {copy_label, "_context"}, result.context_ref
      );
    if (status.ok() && source.staging_mapping != null)
      status = clone_owned_mapping_value(
        source.staging_mapping, {copy_label, "_staging"},
        result.staging_mapping
      );
    if (status.ok() && source.query_mapping != null)
      status = source.query_mapping_recovery_only ?
        clone_recovery_mapping_value(
          source.query_mapping, {copy_label, "_query_recovery"},
          result.query_mapping
        ) :
        clone_owned_mapping_value(
          source.query_mapping, {copy_label, "_query"}, result.query_mapping
        );
    if (status.ok())
      status = project_opcode_value(source.create_opcode,
                                    {copy_label, "_create"},
                                    result.create_opcode);
    if (status.ok())
      status = project_opcode_value(source.modify_opcode,
                                    {copy_label, "_modify"},
                                    result.modify_opcode);
    if (status.ok())
      status = project_opcode_value(source.delete_opcode,
                                    {copy_label, "_delete"},
                                    result.delete_opcode);
    if (status.ok())
      status = project_opcode_value(source.query_opcode,
                                    {copy_label, "_query_opcode"},
                                    result.query_opcode);
    if (status.ok())
      status = project_opcode_value(source.occ_opcode,
                                    {copy_label, "_occ_opcode"},
                                    result.occ_opcode);
    if (status.ok())
      status = project_ticket_value(source.ambiguous_ticket,
                                    {copy_label, "_ticket"},
                                    result.ambiguous_ticket);
    if (!status.ok())
      result = null;
    return status;
  endfunction

  // 功能：向队列资源副本填充 depth、producer/consumer cursor、IOVA 和 queue plan。
  // 输入/输出及副作用：source 为只读队列，result 为调用方已创建的独立目标，copy_label 命名嵌套 plan；原地更新 result。
  // 失败/边界：source/result 须非空；plan 失败原样传播 status，已复制的标量不回滚，调用方须丢弃整个候选。
  static function automatic rdma_status project_queue_fields(
    rdma_queue_resource source,
    rdma_queue_resource result,
    string copy_label
  );
    rdma_status status;

    result.depth = source.depth;
    result.producer_index = source.producer_index;
    result.consumer_index = source.consumer_index;
    result.producer_wrap = source.producer_wrap;
    result.consumer_wrap = source.consumer_wrap;
    result.queue_iova = source.queue_iova;
    status = project_queue_plan_value(source.queue_plan,
                                      {copy_label, "_queue_plan"},
                                      result.queue_plan);
    return status;
  endfunction

  // 功能：按 handle.kind 分派 Function/PD/MR/CQ/QP/SRQ/CMQ/CEQ/AEQ，复制基础字段和业务子图。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出内建资源副本；CQ 的 programmed_cqc 保留 checked clone，
  //   其它子图遵守各自契约。
  // 失败/边界：空 source/handle、无效 kind、carrier 类型不符返回 INVALID_ARGUMENT；kind 中途变化也拒绝；
  //   CQC clone 空/错型/别名或 null status 返回 INVALID_STATE；子图失败清空 result，不做 registry 提交。
  static function automatic rdma_status project_resource_value(
    rdma_resource source,
    string copy_label,
    output rdma_resource result
  );
    rdma_function source_function;
    rdma_function result_function;
    rdma_pd source_pd;
    rdma_pd result_pd;
    rdma_mr source_mr;
    rdma_mr result_mr;
    rdma_cq source_cq;
    rdma_cq result_cq;
    rdma_cqc_model cloned_cqc;
    rdma_qp source_qp;
    rdma_qp result_qp;
    rdma_srq source_srq;
    rdma_srq result_srq;
    rdma_cmq source_cmq;
    rdma_cmq result_cmq;
    rdma_ceq source_ceq;
    rdma_ceq result_ceq;
    rdma_aeq source_aeq;
    rdma_aeq result_aeq;
    rdma_status status;

    result = null;
    if (source == null || source.handle == null ||
        !rdma_resource_allocator_policy::valid_kind(source.handle.kind))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " resource carrier is structurally incompatible"}
      );

    case (source.handle.kind)
      RDMA_RESOURCE_FUNCTION: begin
        if (!$cast(source_function, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " Function carrier does not match handle kind"}
          );
        result_function = new({copy_label, "_function"});
        result_function.binding = null;
        result = result_function;
      end
      RDMA_RESOURCE_PD: begin
        if (!$cast(source_pd, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " PD carrier does not match handle kind"}
          );
        result_pd = new({copy_label, "_pd"});
        result = result_pd;
      end
      RDMA_RESOURCE_MR: begin
        if (!$cast(source_mr, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " MR carrier does not match handle kind"}
          );
        result_mr = new({copy_label, "_mr"});
        result = result_mr;
      end
      RDMA_RESOURCE_CQ: begin
        if (!$cast(source_cq, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " CQ carrier does not match handle kind"}
          );
        result_cq = new({copy_label, "_cq"});
        result = result_cq;
      end
      RDMA_RESOURCE_QP: begin
        if (!$cast(source_qp, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " QP carrier does not match handle kind"}
          );
        result_qp = new({copy_label, "_qp"});
        result = result_qp;
      end
      RDMA_RESOURCE_SRQ: begin
        if (!$cast(source_srq, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " SRQ carrier does not match handle kind"}
          );
        result_srq = new({copy_label, "_srq"});
        result = result_srq;
      end
      RDMA_RESOURCE_CMQ: begin
        if (!$cast(source_cmq, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " CMQ carrier does not match handle kind"}
          );
        result_cmq = new({copy_label, "_cmq"});
        result = result_cmq;
      end
      RDMA_RESOURCE_CEQ: begin
        if (!$cast(source_ceq, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " CEQ carrier does not match handle kind"}
          );
        result_ceq = new({copy_label, "_ceq"});
        result = result_ceq;
      end
      RDMA_RESOURCE_AEQ: begin
        if (!$cast(source_aeq, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " AEQ carrier does not match handle kind"}
          );
        result_aeq = new({copy_label, "_aeq"});
        result = result_aeq;
      end
      default:
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          {copy_label, " resource kind is invalid"}
        );
    endcase

    status = project_resource_base_fields(source, copy_label, result);
    if (!status.ok()) begin
      result = null;
      return status;
    end

    case (source.handle.kind)
      RDMA_RESOURCE_FUNCTION: begin
        result_function.local_function_id = source_function.local_function_id;
        result_function.global_function_id =
          source_function.global_function_id;
        result_function.rdma_vf_id = source_function.rdma_vf_id;
        result_function.vsi_id = source_function.vsi_id;
        result_function.pfvf_id = source_function.pfvf_id;
        status = project_binding_value(
          source_function.binding, {copy_label, "_binding"},
          result_function.binding
        );
      end
      RDMA_RESOURCE_PD: begin
        result_pd.local_pd_id = source_pd.local_pd_id;
        result_pd.global_pd_id = source_pd.global_pd_id;
      end
      RDMA_RESOURCE_MR: begin
        result_mr.local_mr_id = source_mr.local_mr_id;
        result_mr.global_mr_id = source_mr.global_mr_id;
        status = project_handle_value(
          source_mr.pd_h, {copy_label, "_pd"}, result_mr.pd_h
        );
        result_mr.iova = source_mr.iova;
        result_mr.length = source_mr.length;
        result_mr.lkey = source_mr.lkey;
        result_mr.rkey = source_mr.rkey;
        result_mr.access = source_mr.access;
        result_mr.mr_serial = source_mr.mr_serial;
      end
      RDMA_RESOURCE_CQ: begin
        status = project_queue_fields(source_cq, result_cq, copy_label);
        result_cq.local_cq_id = source_cq.local_cq_id;
        result_cq.global_cq_id = source_cq.global_cq_id;
        result_cq.cqe_size_bytes = source_cq.cqe_size_bytes;
        if (status.ok())
          status = project_handle_value(
            source_cq.ceq_h, {copy_label, "_ceq"}, result_cq.ceq_h
          );
        if (status.ok() && source_cq.programmed_cqc != null) begin
          if (!rdma_deep_copy#(rdma_cqc_model)::try_of(
                source_cq.programmed_cqc, cloned_cqc)) begin
            status = rdma_status::make(
              RDMA_SC_INVALID_STATE,
              {copy_label, " programmed CQC clone failed"}
            );
          end
          else begin
            result_cq.programmed_cqc = cloned_cqc;
          end
        end
      end
      RDMA_RESOURCE_QP: begin
        result_qp.local_qp_id = source_qp.local_qp_id;
        result_qp.global_qp_id = source_qp.global_qp_id;
        result_qp.transport = source_qp.transport;
        result_qp.qp_state = source_qp.qp_state;
        result_qp.sq_depth = source_qp.sq_depth;
        result_qp.rq_depth = source_qp.rq_depth;
        result_qp.sq_producer_index = source_qp.sq_producer_index;
        result_qp.sq_consumer_index = source_qp.sq_consumer_index;
        result_qp.sq_wrap = source_qp.sq_wrap;
        result_qp.sq_consumer_wrap = source_qp.sq_consumer_wrap;
        result_qp.rq_producer_index = source_qp.rq_producer_index;
        result_qp.rq_consumer_index = source_qp.rq_consumer_index;
        result_qp.rq_wrap = source_qp.rq_wrap;
        result_qp.rq_consumer_wrap = source_qp.rq_consumer_wrap;
        result_qp.sq_iova = source_qp.sq_iova;
        result_qp.rq_iova = source_qp.rq_iova;
        status = project_handle_value(
          source_qp.pd_h, {copy_label, "_pd"}, result_qp.pd_h
        );
        if (status.ok())
          status = project_handle_value(
            source_qp.send_cq_h, {copy_label, "_send_cq"},
            result_qp.send_cq_h
          );
        if (status.ok())
          status = project_handle_value(
            source_qp.recv_cq_h, {copy_label, "_recv_cq"},
            result_qp.recv_cq_h
          );
        if (status.ok())
          status = project_handle_value(
            source_qp.srq_h, {copy_label, "_srq"}, result_qp.srq_h
          );
        if (status.ok())
          status = project_qp_plan_value(
            source_qp.qp_plan, {copy_label, "_qp_plan"}, result_qp.qp_plan
          );
        if (status.ok())
          status = project_qpc_value(
            source_qp.programmed_qpc, {copy_label, "_programmed_qpc"},
            result_qp.programmed_qpc
          );
      end
      RDMA_RESOURCE_SRQ: begin
        status = project_queue_fields(source_srq, result_srq, copy_label);
        result_srq.local_srq_id = source_srq.local_srq_id;
        result_srq.global_srq_id = source_srq.global_srq_id;
        result_srq.max_sge = source_srq.max_sge;
        result_srq.limit_threshold = source_srq.limit_threshold;
        if (status.ok())
          status = project_handle_value(
            source_srq.pd_h, {copy_label, "_pd"}, result_srq.pd_h
          );
      end
      RDMA_RESOURCE_CMQ: begin
        status = project_queue_fields(source_cmq, result_cmq, copy_label);
        result_cmq.local_cmq_id = source_cmq.local_cmq_id;
        result_cmq.global_cmq_id = source_cmq.global_cmq_id;
        result_cmq.completion_producer_index =
          source_cmq.completion_producer_index;
        result_cmq.completion_consumer_index =
          source_cmq.completion_consumer_index;
        result_cmq.completion_wrap = source_cmq.completion_wrap;
        result_cmq.completion_consumer_wrap =
          source_cmq.completion_consumer_wrap;
        result_cmq.completion_iova = source_cmq.completion_iova;
      end
      RDMA_RESOURCE_CEQ: begin
        status = project_queue_fields(source_ceq, result_ceq, copy_label);
        result_ceq.local_ceq_id = source_ceq.local_ceq_id;
        result_ceq.global_ceq_id = source_ceq.global_ceq_id;
        result_ceq.function_local_vector = source_ceq.function_local_vector;
        result_ceq.hardware_vector = source_ceq.hardware_vector;
        result_ceq.msix_table_index = source_ceq.msix_table_index;
      end
      RDMA_RESOURCE_AEQ: begin
        status = project_queue_fields(source_aeq, result_aeq, copy_label);
        result_aeq.local_aeq_id = source_aeq.local_aeq_id;
        result_aeq.global_aeq_id = source_aeq.global_aeq_id;
        result_aeq.function_local_vector = source_aeq.function_local_vector;
        result_aeq.hardware_vector = source_aeq.hardware_vector;
        result_aeq.msix_table_index = source_aeq.msix_table_index;
      end
      default: begin
        status = rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          {copy_label, " resource kind changed during projection"}
        );
      end
    endcase

    if (status == null || !status.ok()) begin
      result = null;
      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          {copy_label, " projection returned null status"}
        );
      return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：比较资源 outstanding ID 队列的长度及顺序，保护 manager 拥有的在途账本值。
  // 输入/输出及副作用：只读 lhs/rhs.outstanding_ids；长度相同且每项相等才返回 1，不消费完成。
  // 失败/边界：任一资源为空或长度/元素不同返回 0；两个空数组相等，不按集合排序或去重。
  static function automatic bit same_outstanding_ids(
    rdma_resource lhs,
    rdma_resource rhs
  );
    if (lhs == null || rhs == null ||
        lhs.outstanding_ids.size() != rhs.outstanding_ids.size())
      return 1'b0;
    foreach (lhs.outstanding_ids[i]) begin
      if (lhs.outstanding_ids[i] != rhs.outstanding_ids[i])
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：比较 kind/function_uid/object_id/generation 四字段，判断两个 handle 是否表示同一身份值。
  // 输入/输出及副作用：lhs/rhs 为借用 handle，返回等值 bit，不查询账本或调用虚拟比较器。
  // 失败/边界：双 null 相等、单 null 不等；不检查 X/Z、对象别名、authority 或代际新鲜度。
  static function automatic bit same_handle_instance(rdma_handle lhs,
                                               rdma_handle rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.kind == rhs.kind &&
           lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id &&
           lhs.generation == rhs.generation;
  endfunction

  // 功能：为 binding owner 身份比较转发到统一的四字段 handle 等值规则。
  // 输入/输出及副作用：只读 lhs/rhs，返回 same_handle_instance 的结果；不产生新 handle。
  // 失败/边界：双 null 相等、单 null 不等；等值不代表拥有同一外部 capability。
  static function automatic bit same_handle_value(rdma_handle lhs,
                                            rdma_handle rhs);
    return same_handle_instance(lhs, rhs);
  endfunction

  // 功能：按原顺序比较资源 dependencies 的 handle 身份，保护发布时的依赖拓扑。
  // 输入/输出及副作用：只读 lhs/rhs 的数组长度和四字段身份，返回 bit；不遍历 registry 或扩展传递依赖。
  // 失败/边界：任一资源为空、长度或对应身份不同返回 0；对应双 null handle 相等，不把列表当无序集合。
  static function automatic bit same_dependency_topology(rdma_resource lhs,
                                                  rdma_resource rhs);
    if (lhs == null || rhs == null ||
        lhs.dependencies.size() != rhs.dependencies.size())
      return 1'b0;
    foreach (lhs.dependencies[i]) begin
      if (!same_handle_instance(lhs.dependencies[i], rhs.dependencies[i]))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：比较 binding 公开身份、readiness、DMA/caps/vector 和 PCIe/BAR 值，检测发布时的字段漂移。
  // 输入/输出及副作用：只读 lhs/rhs；返回逐字段等值 bit，不调用 identity snapshot 或接管 dpu_common authority。
  // 失败/边界：双 null binding/PCIe/BAR 按相等处理，单侧 null 或任一受比较值变化返回 0；不证明 opaque identity authority。
  static function automatic bit same_binding_identity(rdma_function_binding lhs,
                                               rdma_function_binding rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.function_uid != rhs.function_uid ||
        lhs.notify_bar_id != rhs.notify_bar_id ||
        lhs.notify_base != rhs.notify_base ||
        lhs.notify_size != rhs.notify_size ||
        lhs.notify_table_sel != rhs.notify_table_sel ||
        lhs.notify_table_index != rhs.notify_table_index ||
        lhs.host_id != rhs.host_id || lhs.pfvf_id != rhs.pfvf_id ||
        lhs.rdma_vf_id != rhs.rdma_vf_id ||
        lhs.global_function_id != rhs.global_function_id ||
        lhs.vsi_id != rhs.vsi_id ||
        lhs.state != rhs.state || lhs.generation != rhs.generation ||
        lhs.notify_valid != rhs.notify_valid ||
        lhs.notify_ready != rhs.notify_ready ||
        lhs.dmi_valid != rhs.dmi_valid || lhs.dmi_ready != rhs.dmi_ready ||
        lhs.vft_valid != rhs.vft_valid || lhs.vft_ready != rhs.vft_ready ||
        !same_handle_value(lhs.owner_h, rhs.owner_h))
      return 1'b0;
    if (lhs.queue_dma.requester_bdf != rhs.queue_dma.requester_bdf ||
        lhs.queue_dma.pasid_valid != rhs.queue_dma.pasid_valid ||
        lhs.queue_dma.pasid != rhs.queue_dma.pasid ||
        lhs.queue_dma.dma_domain_valid != rhs.queue_dma.dma_domain_valid ||
        lhs.queue_dma.dma_domain_id != rhs.queue_dma.dma_domain_id)
      return 1'b0;
    if (lhs.queue_caps.min_cq_depth != rhs.queue_caps.min_cq_depth ||
        lhs.queue_caps.max_cq_depth != rhs.queue_caps.max_cq_depth ||
        lhs.queue_caps.min_srq_depth != rhs.queue_caps.min_srq_depth ||
        lhs.queue_caps.max_srq_depth != rhs.queue_caps.max_srq_depth ||
        lhs.queue_caps.max_ceq_depth != rhs.queue_caps.max_ceq_depth ||
        lhs.queue_caps.max_aeq_depth != rhs.queue_caps.max_aeq_depth ||
        lhs.queue_caps.max_wq_sge != rhs.queue_caps.max_wq_sge ||
        lhs.queue_caps.max_queue_ring_bytes !=
          rhs.queue_caps.max_queue_ring_bytes ||
        lhs.queue_caps.max_sgb_bytes != rhs.queue_caps.max_sgb_bytes)
      return 1'b0;
    if (lhs.interrupt_vectors.size() != rhs.interrupt_vectors.size())
      return 1'b0;
    foreach (lhs.interrupt_vectors[i]) begin
      if (lhs.interrupt_vectors[i].function_local_vector !=
            rhs.interrupt_vectors[i].function_local_vector ||
          lhs.interrupt_vectors[i].hardware_eq_vector !=
            rhs.interrupt_vectors[i].hardware_eq_vector ||
          lhs.interrupt_vectors[i].msix_table_index !=
            rhs.interrupt_vectors[i].msix_table_index ||
          lhs.interrupt_vectors[i].enabled !=
            rhs.interrupt_vectors[i].enabled)
        return 1'b0;
    end
    if (lhs.pcie == null || rhs.pcie == null)
      return lhs.pcie == rhs.pcie;
    if (lhs.pcie.bdf != rhs.pcie.bdf ||
        lhs.pcie.parent_pf_bdf != rhs.pcie.parent_pf_bdf ||
        lhs.pcie.vf_index != rhs.pcie.vf_index ||
        lhs.pcie.mse != rhs.pcie.mse || lhs.pcie.bme != rhs.pcie.bme)
      return 1'b0;
    foreach (lhs.pcie.bar[i]) begin
      if (lhs.pcie.bar[i] == null || rhs.pcie.bar[i] == null) begin
        if (lhs.pcie.bar[i] != rhs.pcie.bar[i])
          return 1'b0;
      end
      else if (lhs.pcie.bar[i].bar_id != rhs.pcie.bar[i].bar_id ||
               lhs.pcie.bar[i].base != rhs.pcie.bar[i].base ||
               lhs.pcie.bar[i].size != rhs.pcie.bar[i].size ||
               lhs.pcie.bar[i].enabled != rhs.pcie.bar[i].enabled)
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：检查资源副本与 authoritative 的身份、owner、依赖、outstanding IDs 及各 kind 的 manager-owned 字段。
  // 输入/输出及副作用：candidate/authoritative 为只读资源；返回 status，不查询 registry，也不允许调用方借此绕过提交门禁。
  // 失败/边界：空资源/handle、身份/拓扑变化、kind 类型转换失败或各类固定 ID/依赖/binding 变化返回 INVALID_ARGUMENT；
  //   不比较可更新业务字段，不证明 epoch/source 新鲜度；status factory 仍可能同步重入。
  static function automatic rdma_status publication_identity_status(
    rdma_resource candidate,
    rdma_resource authoritative
  );
    rdma_function candidate_function;
    rdma_function authoritative_function;
    rdma_pd candidate_pd;
    rdma_pd authoritative_pd;
    rdma_mr candidate_mr;
    rdma_mr authoritative_mr;
    rdma_cq candidate_cq;
    rdma_cq authoritative_cq;
    rdma_qp candidate_qp;
    rdma_qp authoritative_qp;
    rdma_srq candidate_srq;
    rdma_srq authoritative_srq;
    rdma_cmq candidate_cmq;
    rdma_cmq authoritative_cmq;
    rdma_ceq candidate_ceq;
    rdma_ceq authoritative_ceq;
    rdma_aeq candidate_aeq;
    rdma_aeq authoritative_aeq;
    bit fields_match;

    if (candidate == null || authoritative == null ||
        candidate.handle == null || authoritative.handle == null ||
        candidate.handle.kind != authoritative.handle.kind ||
        !same_handle_instance(candidate.handle, authoritative.handle) ||
        !same_handle_instance(candidate.owner, authoritative.owner) ||
        !same_dependency_topology(candidate, authoritative) ||
        !same_outstanding_ids(candidate, authoritative))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "published resource identity or topology changed"
      );

    fields_match = 1'b0;
    case (authoritative.handle.kind)
      RDMA_RESOURCE_FUNCTION: begin
        if ($cast(candidate_function, candidate) &&
            $cast(authoritative_function, authoritative))
          fields_match = candidate_function.local_function_id ==
                      authoritative_function.local_function_id &&
                    candidate_function.global_function_id ==
                      authoritative_function.global_function_id &&
                    candidate_function.rdma_vf_id ==
                      authoritative_function.rdma_vf_id &&
                    candidate_function.vsi_id == authoritative_function.vsi_id &&
                    candidate_function.pfvf_id ==
                      authoritative_function.pfvf_id &&
                    same_binding_identity(candidate_function.binding,
                                          authoritative_function.binding);
      end
      RDMA_RESOURCE_PD: begin
        if ($cast(candidate_pd, candidate) &&
            $cast(authoritative_pd, authoritative))
          fields_match = candidate_pd.local_pd_id == authoritative_pd.local_pd_id &&
                    candidate_pd.global_pd_id == authoritative_pd.global_pd_id;
      end
      RDMA_RESOURCE_MR: begin
        if ($cast(candidate_mr, candidate) &&
            $cast(authoritative_mr, authoritative))
          fields_match = candidate_mr.local_mr_id == authoritative_mr.local_mr_id &&
                    candidate_mr.global_mr_id == authoritative_mr.global_mr_id &&
                    same_handle_instance(candidate_mr.pd_h,
                                         authoritative_mr.pd_h);
      end
      RDMA_RESOURCE_CQ: begin
        if ($cast(candidate_cq, candidate) &&
            $cast(authoritative_cq, authoritative))
          fields_match = candidate_cq.local_cq_id == authoritative_cq.local_cq_id &&
                    candidate_cq.global_cq_id == authoritative_cq.global_cq_id &&
                    same_handle_instance(candidate_cq.ceq_h,
                                         authoritative_cq.ceq_h);
      end
      RDMA_RESOURCE_QP: begin
        if ($cast(candidate_qp, candidate) &&
            $cast(authoritative_qp, authoritative))
          fields_match = candidate_qp.local_qp_id == authoritative_qp.local_qp_id &&
                    candidate_qp.global_qp_id == authoritative_qp.global_qp_id &&
                    same_handle_instance(candidate_qp.pd_h,
                                         authoritative_qp.pd_h) &&
                    same_handle_instance(candidate_qp.send_cq_h,
                                         authoritative_qp.send_cq_h) &&
                    same_handle_instance(candidate_qp.recv_cq_h,
                                         authoritative_qp.recv_cq_h) &&
                    same_handle_instance(candidate_qp.srq_h,
                                         authoritative_qp.srq_h);
      end
      RDMA_RESOURCE_SRQ: begin
        if ($cast(candidate_srq, candidate) &&
            $cast(authoritative_srq, authoritative))
          fields_match = candidate_srq.local_srq_id ==
                      authoritative_srq.local_srq_id &&
                    candidate_srq.global_srq_id ==
                      authoritative_srq.global_srq_id &&
                    same_handle_instance(candidate_srq.pd_h,
                                         authoritative_srq.pd_h);
      end
      RDMA_RESOURCE_CMQ: begin
        if ($cast(candidate_cmq, candidate) &&
            $cast(authoritative_cmq, authoritative))
          fields_match = candidate_cmq.local_cmq_id ==
                      authoritative_cmq.local_cmq_id &&
                    candidate_cmq.global_cmq_id ==
                      authoritative_cmq.global_cmq_id;
      end
      RDMA_RESOURCE_CEQ: begin
        if ($cast(candidate_ceq, candidate) &&
            $cast(authoritative_ceq, authoritative))
          fields_match = candidate_ceq.local_ceq_id ==
                      authoritative_ceq.local_ceq_id &&
                    candidate_ceq.global_ceq_id ==
                      authoritative_ceq.global_ceq_id;
      end
      RDMA_RESOURCE_AEQ: begin
        if ($cast(candidate_aeq, candidate) &&
            $cast(authoritative_aeq, authoritative))
          fields_match = candidate_aeq.local_aeq_id ==
                      authoritative_aeq.local_aeq_id &&
                    candidate_aeq.global_aeq_id ==
                      authoritative_aeq.global_aeq_id;
      end
      // 未识别 kind 保持入口的 false；显式写出默认分支，避免把无匹配当成成功。
      default: fields_match = 1'b0;
    endcase
    if (!fields_match)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "published resource manager-owned fields changed"
      );
    return rdma_status::success();
  endfunction

  // 功能：生成对外资源快照，并检查投影后身份、依赖与 manager-owned 字段仍等于源。
  // 输入/输出及副作用：source/copy_label 为输入，result 输出经 publication_identity_status 核对的副本；不登记或替换资源。
  // 失败/边界：结构投影或身份检查失败传播 status，后者清空 result；成功不代表之后仍新鲜，caller 须保留 epoch/source 门禁。
  static function automatic rdma_status project_public_resource_value(
    rdma_resource source,
    string copy_label,
    output rdma_resource result
  );
    rdma_status status;

    status = project_resource_value(source, copy_label, result);
    if (!status.ok())
      return status;
    status = publication_identity_status(result, source);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：提供对外 recovery 快照入口，沿用完整 recovery 对象图投影和 authority 检查。
  // 输入/输出及副作用：source/copy_label 为输入，result 与返回 status 直接来自 project_recovery_value；不发布 recovery。
  // 失败/边界：空 record 返回 INVALID_ARGUMENT；嵌套投影失败清空 result 并传播 status；不执行恢复或验证与 live resource 匹配。
  static function automatic rdma_status project_public_recovery_value(
    rdma_recovery_record source,
    string copy_label,
    output rdma_recovery_record result
  );
    return project_recovery_value(source, copy_label, result);
  endfunction
endclass
