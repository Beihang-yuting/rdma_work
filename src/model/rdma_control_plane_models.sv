// 目录：协议与资源模型层 model/rdma_control_plane_models.sv。
// 职责：实现 rdma_control_plane_models 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_control_plane_models.sv 属于模型层，描述语义请求、资源快照、DMA 映射及生命周期数据。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

typedef enum bit [3:0] {
  RDMA_CTRL_STEP_RESOURCE_RESERVED,
  RDMA_CTRL_STEP_BACKING_ATTACHED,
  RDMA_CTRL_STEP_HMC_ATTACHED,
  RDMA_CTRL_STEP_HW_KEY_ALLOCATED,
  RDMA_CTRL_STEP_REGISTRY_PROGRAMMED,
  RDMA_CTRL_STEP_REGISTRY_ACTIVE,
  RDMA_CTRL_STEP_HW_OCC_FLUSHED,
  RDMA_CTRL_STEP_HW_MR_DEREGISTERED,
  RDMA_CTRL_STEP_HW_DRAINED,
  RDMA_CTRL_STEP_BACKING_RELEASED,
  RDMA_CTRL_STEP_RESOURCE_RELEASED,
  RDMA_CTRL_STEP_HW_CONTEXT_CREATED,
  RDMA_CTRL_STEP_HW_CONTEXT_DELETED
} rdma_control_step_e;

// 控制面准入时需要从请求中复验的目标句柄来源：无目标、destroy 请求的 target_h、
//   modify QP 请求的 qp_h。
typedef enum bit [1:0] {
  RDMA_CTRL_TARGET_NONE,
  RDMA_CTRL_TARGET_DESTROY,
  RDMA_CTRL_TARGET_MODIFY_QP
} rdma_control_target_e;

// 功能：rdma_control_step_valid 比较 step 与当前 authority/状态字段，返回布尔结果供上层执行精确分支。
// 输入/输出及副作用：step（输入）；rdma_control_step_valid 读取 step 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
// 失败/边界：rdma_control_step_valid 只读输入并返回 bit；边界由函数体现有分支决定，不修改状态或转移资源。
function automatic bit rdma_control_step_valid(rdma_control_step_e step);
  return step inside {
    RDMA_CTRL_STEP_RESOURCE_RESERVED,
    RDMA_CTRL_STEP_BACKING_ATTACHED,
    RDMA_CTRL_STEP_HMC_ATTACHED,
    RDMA_CTRL_STEP_HW_KEY_ALLOCATED,
    RDMA_CTRL_STEP_REGISTRY_PROGRAMMED,
    RDMA_CTRL_STEP_REGISTRY_ACTIVE,
    RDMA_CTRL_STEP_HW_OCC_FLUSHED,
    RDMA_CTRL_STEP_HW_MR_DEREGISTERED,
    RDMA_CTRL_STEP_HW_DRAINED,
    RDMA_CTRL_STEP_BACKING_RELEASED,
    RDMA_CTRL_STEP_RESOURCE_RELEASED,
    RDMA_CTRL_STEP_HW_CONTEXT_CREATED,
    RDMA_CTRL_STEP_HW_CONTEXT_DELETED
  };
endfunction

// 功能：rdma_control_step_is_hardware 根据 step 的 函数体条件 判断队列/角色/依赖条件，返回 bit 供上层选择分支；不修改运行时账本。
// 输入/输出及副作用：step（输入）；rdma_control_step_is_hardware 读取 step 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
// 失败/边界：rdma_control_step_is_hardware 只读输入并返回 bit；边界由函数体现有分支决定，不修改状态或转移资源。
function automatic bit rdma_control_step_is_hardware(
  rdma_control_step_e step
);
  return step inside {
    RDMA_CTRL_STEP_HW_KEY_ALLOCATED,
    RDMA_CTRL_STEP_HW_OCC_FLUSHED,
    RDMA_CTRL_STEP_HW_MR_DEREGISTERED,
    RDMA_CTRL_STEP_HW_DRAINED,
    RDMA_CTRL_STEP_HW_CONTEXT_CREATED,
    RDMA_CTRL_STEP_HW_CONTEXT_DELETED
  };
endfunction

// 功能：rdma_control_nested_status 规范化控制面模型所调用的 virtual validator
//       返回值，确保恢复校验不会对 null status 解引用。
// 输入/输出及副作用：status 和 label 为输入；非空 status 原样返回，null status
//       转换为 INVALID_STATE；函数不修改模型、快照、句柄或资源账本。
// 失败/边界：下游 validator 返回 null 时生成带上下文的确定性失败；调用方收到
//       该状态后必须停止当前恢复分支，不能把 null 当作成功或继续读取字段。
function automatic rdma_status rdma_control_nested_status(
  rdma_status status,
  string label
);
  if (status == null)
    return rdma_status::make(
      RDMA_SC_INVALID_STATE,
      {label, " returned null status"}
    );
  return status;
endfunction

class rdma_mr_backing_desc extends uvm_object;
  `uvm_object_utils(rdma_mr_backing_desc)

  rdma_function_handle function_h;
  rdma_bdf_t requester_bdf;
  bit pasid_valid;
  bit [19:0] pasid;
  rdma_backing_ref backing_refs[$];
  rdma_hmc_ref hmc_refs[$];
  rdma_mr_page_layout page_layout;

  // 功能：构造 rdma_mr_backing_desc，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：function_h=null；requester_bdf='0；pasid_valid=1'b0；pasid='0；page_layout=rdma_mr_page_layout::type_id::create("page_layout")。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mr_backing_desc 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mr_backing_desc");
    super.new(name);
    function_h = null;
    requester_bdf = '0;
    pasid_valid = 1'b0;
    pasid = '0;
    page_layout = rdma_mr_page_layout::type_id::create("page_layout");
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“MR backing authority is incomplete”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、function_h、function_h.kind、page_layout、backing_refs、hmc_refs 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“MR backing authority is incomplete”“MR backing reference is null”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;

    if (function_h == null ||
        function_h.kind != RDMA_RESOURCE_FUNCTION ||
        page_layout == null || backing_refs.size() == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MR backing authority is incomplete");
    foreach (backing_refs[i]) begin
      if (backing_refs[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MR backing reference is null");
      status = rdma_status::nonnull(
        backing_refs[i].validate(),
        "MR backing validation returned null"
      );
      if (!status.ok())
        return status;
    end
    foreach (hmc_refs[i]) begin
      if (hmc_refs[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MR HMC reference is null");
      status = rdma_status::nonnull(hmc_refs[i].validate(), "MR HMC validation returned null");
      if (!status.ok())
        return status;
    end
    status = rdma_status::nonnull(
      page_layout.validate(),
      "MR page layout validation returned null"
    );
    if (!status.ok())
      return status;
    case (page_layout.pbl_mode)
      RDMA_MR_PBL0:
        if (backing_refs.size() != 1 || hmc_refs.size() != 0 ||
            page_layout.pba0 != backing_refs[0].mapping.backing_addr)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL0 backing does not match its PBA");
      RDMA_MR_PBL1:
        if (backing_refs.size() != 2 || hmc_refs.size() != 0 ||
            page_layout.pba0 != backing_refs[0].mapping.backing_addr ||
            page_layout.pba1 != backing_refs[1].mapping.backing_addr)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL1 backing does not match its PBAs");
      RDMA_MR_PBL2:
        if (hmc_refs.size() != 1 || !hmc_refs[0].index_valid ||
            !page_layout.first_pbl_index_valid ||
            hmc_refs[0].first_pbl_index != page_layout.first_pbl_index)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "PBL2 backing does not match its HMC lease"
          );
      default:;
    endcase
    return rdma_status::success();
  endfunction

  // 功能：将 rhs 中 rdma_mr_backing_desc 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（MR backing descriptor copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_mr_backing_desc rhs_desc;
    rdma_backing_ref cloned_backing_ref;
    rdma_hmc_ref cloned_hmc_ref;

    super.do_copy(rhs);
    if (!$cast(rhs_desc, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "MR backing descriptor copy mismatch")
    function_h = rdma_clone_function_handle_value(rhs_desc.function_h,
                                                   "MR backing descriptor");
    requester_bdf = rhs_desc.requester_bdf;
    pasid_valid = rhs_desc.pasid_valid;
    pasid = rhs_desc.pasid;
    backing_refs.delete();
    foreach (rhs_desc.backing_refs[i]) begin
      if (rhs_desc.backing_refs[i] == null) begin
        backing_refs.push_back(null);
      end
      else begin
        cloned_backing_ref = rdma_deep_copy#(rdma_backing_ref)::of(
          rhs_desc.backing_refs[i], "MR backing reference clone mismatch");
        backing_refs.push_back(cloned_backing_ref);
      end
    end
    hmc_refs.delete();
    foreach (rhs_desc.hmc_refs[i]) begin
      if (rhs_desc.hmc_refs[i] == null) begin
        hmc_refs.push_back(null);
      end
      else begin
        cloned_hmc_ref = rdma_deep_copy#(rdma_hmc_ref)::of(
          rhs_desc.hmc_refs[i], "MR HMC reference clone mismatch");
        hmc_refs.push_back(cloned_hmc_ref);
      end
    end
    page_layout = rdma_deep_copy#(rdma_mr_page_layout)::of(
      rhs_desc.page_layout, "MR page layout clone mismatch");
  endfunction
endclass

class rdma_control_result extends uvm_object;
  `uvm_object_utils(rdma_control_result)

  longint unsigned transaction_id;
  rdma_status status;
  rdma_status primary_status;
  rdma_status rollback_statuses[$];
  rdma_handle resource_h;
  rdma_control_step_e completed_steps[$];
  rdma_resource_state_e final_resource_state;
  bit final_resource_state_known;
  bit recovery_required;

  // 功能：构造 rdma_control_result，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：transaction_id=0；status=null；primary_status=null；resource_h=null；final_resource_state=RDMA_RESOURCE_NEW；final_resource_state_known=1'b0；recovery_required=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_control_result 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_control_result");
    super.new(name);
    transaction_id = 0;
    status = null;
    primary_status = null;
    resource_h = null;
    final_resource_state = RDMA_RESOURCE_NEW;
    final_resource_state_known = 1'b0;
    recovery_required = 1'b0;
  endfunction

  // 功能：ok 按函数体读取当前字段并生成 bit 结果，供调用方进行诊断或分支决策；不修改外部资源。
  // 输入/输出及副作用：无显式参数；ok 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  function bit ok();
    return status != null && status.ok();
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“control result status is incomplete”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、primary_status、rollback_statuses、completed_steps、final_resource_state、final_resource_state_known、recovery_required 并使用字段 rdma_status、primary_status、rollback_statuses、completed_steps、final_resource_state、final_resource_state_known、recovery_required；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“control result status is incomplete”“control result rollback status is null”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    if (status == null || primary_status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "control result status is incomplete");
    foreach (rollback_statuses[i]) begin
      if (rollback_statuses[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "control result rollback status is null");
    end
    foreach (completed_steps[i]) begin
      if (!rdma_control_step_valid(completed_steps[i]))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "control result step is invalid");
    end
    if (!(final_resource_state inside {
          RDMA_RESOURCE_NEW, RDMA_RESOURCE_ALLOCATED,
          RDMA_RESOURCE_PROGRAMMED, RDMA_RESOURCE_ACTIVE,
          RDMA_RESOURCE_QUIESCING, RDMA_RESOURCE_RELEASED,
          RDMA_RESOURCE_ERROR}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "control result final state is invalid");
    if (!final_resource_state_known &&
        final_resource_state != RDMA_RESOURCE_NEW)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "unknown control result final state is not canonical"
      );
    if (recovery_required &&
        (!final_resource_state_known ||
         status.code != RDMA_SC_RECOVERY_REQUIRED ||
         final_resource_state != RDMA_RESOURCE_ERROR))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "recovery-required result is not an ERROR recovery result"
      );
    return rdma_status::success();
  endfunction

  // 功能：将 rhs 中 rdma_control_result 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（control result copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_control_result rhs_result;

    super.do_copy(rhs);
    if (!$cast(rhs_result, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "control result copy mismatch")
    transaction_id = rhs_result.transaction_id;
    status = rdma_cmq_clone_status_value(rhs_result.status);
    primary_status = rdma_cmq_clone_status_value(rhs_result.primary_status);
    rollback_statuses.delete();
    foreach (rhs_result.rollback_statuses[i])
      rollback_statuses.push_back(
        rdma_cmq_clone_status_value(rhs_result.rollback_statuses[i])
      );
    resource_h = rdma_clone_handle_value(rhs_result.resource_h,
                                         "control result");
    completed_steps = rhs_result.completed_steps;
    final_resource_state = rhs_result.final_resource_state;
    final_resource_state_known = rhs_result.final_resource_state_known;
    recovery_required = rhs_result.recovery_required;
  endfunction
endclass

typedef enum bit [1:0] { RDMA_QP_RECOVER_CREATE_ROLLBACK,
                         RDMA_QP_RECOVER_MODIFY_RECONCILE,
                         RDMA_QP_RECOVER_NORMAL_DESTROY }
  rdma_qp_recovery_intent_e;

typedef enum bit [2:0] { RDMA_QP_AMBIG_NONE, RDMA_QP_AMBIG_CREATE,
                         RDMA_QP_AMBIG_MODIFY, RDMA_QP_AMBIG_DELETE,
                         RDMA_QP_AMBIG_OCC_FLUSH }
  rdma_qp_ambiguous_operation_e;

// 功能：rdma_qp_recovery_mapping_status 校验 mapping、owner、qp_h、label 与当前对象状态的一致性，并显式处理“mapping is missing”等拒绝条件，返回 rdma_status 供上层决定是否提交。
// 输入/输出及副作用：mapping（输入）、owner（输入）、qp_h（输入）、label（输入）；rdma_qp_recovery_mapping_status 读取 mapping、owner、qp_h、label 并使用字段 rdma_status、value；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_qp_recovery_mapping_status 返回 RDMA_SC_INVALID_STATE、RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_qp_recovery_mapping_status(
  rdma_dma_mapping mapping,
  rdma_function_handle owner,
  rdma_handle qp_h,
  string label
);
  if (mapping == null)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             {label, " mapping is missing"});
  if (mapping.state != RDMA_MAPPING_ACTIVE || mapping.size != 512 ||
      (mapping.iova.value & 64'h1ff) != 0 ||
      (mapping.backing_addr.value & 64'h1ff) != 0)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             {label, " mapping is not active 512-byte authority"});
  if (mapping.function_h == null ||
      !mapping.function_h.same_instance(owner))
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " mapping Function does not match"});
  if (mapping.owner_h == null || !mapping.owner_h.same_instance(qp_h))
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             {label, " mapping QP owner does not match"});
  return rdma_status::success();
endfunction

// 功能：在 rdma_control_result 中，rdma_qp_recovery_context_equivalent 比较恢复记录中的 QP 上下文/opcode 与当前请求是否语义等价，避免错误重放。
// 输入/输出及副作用：lhs（输入）、rhs（输入）；rdma_qp_recovery_context_equivalent 读取 lhs、rhs 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
// 失败/边界：rdma_qp_recovery_context_equivalent 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
function automatic bit rdma_qp_recovery_context_equivalent(
  rdma_context_backing_ref lhs,
  rdma_context_backing_ref rhs
);
  rdma_queue_slot_token_contract lhs_token;
  rdma_queue_slot_token_contract rhs_token;

  if (lhs == null || rhs == null || lhs.owner == null || rhs.owner == null ||
      !lhs.owner.same_instance(rhs.owner) ||
      lhs.resource_kind != rhs.resource_kind || lhs.local_id != rhs.local_id ||
      lhs.shadow_pointer_base.value != rhs.shadow_pointer_base.value ||
      lhs.slot_length != rhs.slot_length ||
      lhs.shadow_view_offset != rhs.shadow_view_offset ||
      lhs.shadow_view_length != rhs.shadow_view_length ||
      lhs.release_complete != rhs.release_complete ||
      lhs.hmc_ref == null || rhs.hmc_ref == null ||
      lhs.hmc_ref.owner == null || rhs.hmc_ref.owner == null ||
      !lhs.hmc_ref.owner.same_instance(rhs.hmc_ref.owner) ||
      lhs.hmc_ref.object_kind != rhs.hmc_ref.object_kind ||
      lhs.hmc_ref.address.value != rhs.hmc_ref.address.value ||
      lhs.hmc_ref.size != rhs.hmc_ref.size ||
      lhs.hmc_ref.first_pbl_index != rhs.hmc_ref.first_pbl_index ||
      lhs.hmc_ref.index_valid != rhs.hmc_ref.index_valid ||
      lhs.hmc_ref.ownership != rhs.hmc_ref.ownership ||
      lhs.hmc_ref.release_complete != rhs.hmc_ref.release_complete ||
      !$cast(lhs_token, lhs.slot_token) ||
      !$cast(rhs_token, rhs.slot_token) ||
      lhs_token.completion_authority == null ||
      rhs_token.completion_authority == null ||
      lhs_token.completion_authority !== rhs_token.completion_authority)
    return 1'b0;
  return 1'b1;
endfunction

// 功能：rdma_qp_recovery_ref_status 校验 backing_ref、role_complete、label 与当前对象状态的一致性，并显式处理“backing authority is missing”等拒绝条件，返回 rdma_status 供上层决定是否提交。
// 输入/输出及副作用：backing_ref（输入）、role_complete（输入）、label（输入）；rdma_qp_recovery_ref_status 读取 backing_ref、role_complete、label 并使用字段 mapping.state；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_qp_recovery_ref_status 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_qp_recovery_ref_status(
  rdma_qp_backing_ref backing_ref,
  bit role_complete,
  string label
);
  if (backing_ref == null || backing_ref.mapping == null)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             {label, " backing authority is missing"});
  if (backing_ref.mapping.state != RDMA_MAPPING_ACTIVE &&
      role_complete && backing_ref.mapping.state == RDMA_MAPPING_RELEASED)
    backing_ref.mapping.state = RDMA_MAPPING_ACTIVE;
  if (backing_ref.mapping.state != RDMA_MAPPING_ACTIVE)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             {label, " pending backing is not active"});
  foreach (backing_ref.additional_segments[i]) begin
    if (backing_ref.additional_segments[i] == null ||
        backing_ref.additional_segments[i].mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               {label, " segment authority is missing"});
    if (backing_ref.additional_segments[i].mapping.state != RDMA_MAPPING_ACTIVE &&
        role_complete && backing_ref.additional_segments[i].mapping.state ==
          RDMA_MAPPING_RELEASED)
      backing_ref.additional_segments[i].mapping.state = RDMA_MAPPING_ACTIVE;
    if (backing_ref.additional_segments[i].mapping.state != RDMA_MAPPING_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               {label, " pending segment is not active"});
  end
  return rdma_status::success();
endfunction

// 功能：在 rdma_control_result 中，rdma_qp_recovery_opcode_equivalent 比较恢复记录中的 QP 上下文/opcode 与当前请求是否语义等价，避免错误重放。
// 输入/输出及副作用：lhs（输入）、rhs（输入）；rdma_qp_recovery_opcode_equivalent 读取 lhs、rhs 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
// 失败/边界：rdma_qp_recovery_opcode_equivalent 只读输入并返回 bit；边界由函数体现有分支决定，不修改状态或转移资源。
function automatic bit rdma_qp_recovery_opcode_equivalent(
  rdma_cmq_opcode_key lhs,
  rdma_cmq_opcode_key rhs
);
  return lhs != null && rhs != null &&
         lhs.profile_name == rhs.profile_name && lhs.opcode == rhs.opcode &&
         lhs.variant == rhs.variant;
endfunction

// 功能：rdma_qp_partial_plan_authority 根据 plan、owner、qp_h 执行 rdma_status 结果转换，具体更新字段 owner、qp_h、retained_ref；失败时返回 RDMA_SC_INVALID_STATE，保持已登记资源和输出不变。
// 输入/输出及副作用：plan（输入）、owner（输出）、qp_h（输出）；rdma_qp_partial_plan_authority 读取 plan、owner、qp_h 并使用字段 owner、qp_h、retained_ref，并写入 owner、qp_h；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_qp_partial_plan_authority 返回 RDMA_SC_INVALID_STATE；具体拒绝条件包括 “partial QP recovery plan is missing”；“partial QP recovery has no registry mapping authority”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
function automatic rdma_status rdma_qp_partial_plan_authority(
  rdma_qp_backing_plan plan,
  output rdma_function_handle owner,
  output rdma_handle qp_h
);
  rdma_qp_backing_ref retained_ref;

  owner = null;
  qp_h = null;
  retained_ref = null;
  if (plan == null)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "partial QP recovery plan is missing");
  if (plan.sq_ref != null)
    retained_ref = plan.sq_ref;
  else if (plan.sq_pd_ref != null)
    retained_ref = plan.sq_pd_ref;
  else if (plan.rq_ref != null)
    retained_ref = plan.rq_ref;
  else if (plan.rq_pd_ref != null)
    retained_ref = plan.rq_pd_ref;
  else if (plan.urc_refs.size() != 0)
    retained_ref = plan.urc_refs[0];
  if (retained_ref == null || retained_ref.mapping == null ||
      retained_ref.mapping.function_h == null ||
      retained_ref.mapping.owner_h == null ||
      retained_ref.mapping.owner_h.kind != RDMA_RESOURCE_QP)
    return rdma_status::make(
      RDMA_SC_INVALID_STATE,
      "partial QP recovery has no registry mapping authority"
    );
  owner = retained_ref.mapping.function_h;
  qp_h = retained_ref.mapping.owner_h;
  return rdma_status::success();
endfunction

class rdma_qp_recovery_state extends uvm_object;
  // recovery state 保存硬件不确定期间的不可伪造 authority 和逐角色进度。
  `uvm_object_utils(rdma_qp_recovery_state)
  rdma_qp_recovery_intent_e intent;
  rdma_qp_ambiguous_operation_e ambiguous_operation;
  rdma_queue_backing_role_e ambiguous_role;
  rdma_qpc_model prior_qpc;
  rdma_qpc_model candidate_qpc;
  rdma_qp_backing_plan qp_plan;
  rdma_context_backing_ref context_ref;
  rdma_dma_mapping staging_mapping;
  rdma_dma_mapping query_mapping;
  // Presence evidence obtained from a durable QPC_QUERY image.  The mapping
  // itself may remain retained until its opaque release completion is proven;
  // these fields let a retry skip a second query side effect.
  bit query_presence_known;
  rdma_hw_presence_e query_presence;
  // Ticketless modify failures still carry a pending hardware/cleanup step.
  // This marker permits durable ERROR recovery authority when the adapter did
  // not return a CMQ ticket (for example after encode/write or staging-release
  // failure).
  bit has_pending_hardware_step;
  // A query allocation can fail after returning an adapter-owned mapping with
  // malformed public geometry.  Keep that capability in a recovery-only form
  // until its opaque release completion is proven; it must never be used as a
  // QPC_QUERY buffer.
  bit query_mapping_recovery_only;
  // Destroy progress is persisted separately from backing cleanup. These
  // fences prevent recovery retries from reissuing a definitive ERROR
  // transition or QPC_DELETE after the device has already accepted it.
  bit error_modify_complete;
  bit delete_complete;
  rdma_cmq_opcode_key create_opcode;
  rdma_cmq_opcode_key modify_opcode;
  rdma_cmq_opcode_key delete_opcode;
  rdma_cmq_opcode_key query_opcode;
  rdma_cmq_opcode_key occ_opcode;
  rdma_cmq_ticket ambiguous_ticket;
  bit role_complete[21];

  // 功能：构造 rdma_qp_recovery_state，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：intent=RDMA_QP_RECOVER_CREATE_ROLLBACK；ambiguous_operation=RDMA_QP_AMBIG_NONE；ambiguous_role=RDMA_QUEUE_ROLE_QP_SQ_RING；prior_qpc=null；candidate_qpc=null；qp_plan=null；context_ref=null；staging_mapping=null；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_qp_recovery_state 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_qp_recovery_state");
    super.new(name);
    intent = RDMA_QP_RECOVER_CREATE_ROLLBACK;
    ambiguous_operation = RDMA_QP_AMBIG_NONE;
    ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_RING;
    prior_qpc = null;
    candidate_qpc = null;
    qp_plan = null;
    context_ref = null;
    staging_mapping = null;
    query_mapping = null;
    query_presence_known = 1'b0;
    query_presence = RDMA_HW_PRESENCE_UNKNOWN;
    has_pending_hardware_step = 1'b0;
    query_mapping_recovery_only = 1'b0;
    error_modify_complete = 1'b0;
    delete_complete = 1'b0;
    create_opcode = null;
    modify_opcode = null;
    delete_opcode = null;
    query_opcode = null;
    occ_opcode = null;
    ambiguous_ticket = null;
    foreach (role_complete[i]) role_complete[i] = 0;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“QP recovery enum is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、intent、ambiguous_operation、ambiguous_role、context_ref、qp_plan.context_ref、role_complete、i 并使用字段 preprogram_publication、status、cloned_plan_object、recovery_qp_h；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE、RDMA_SC_RECOVERY_REQUIRED；典型拒绝条件为“QP recovery enum is invalid”“QP OCC ambiguity role is invalid”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;
    rdma_qp_backing_plan validation_plan;
    rdma_handle recovery_qp_h;
    rdma_function_handle recovery_owner;
    bit preprogram_publication;

    if (!(intent inside {RDMA_QP_RECOVER_CREATE_ROLLBACK,
                         RDMA_QP_RECOVER_MODIFY_RECONCILE,
                         RDMA_QP_RECOVER_NORMAL_DESTROY}) ||
        !(ambiguous_operation inside {RDMA_QP_AMBIG_NONE, RDMA_QP_AMBIG_CREATE,
                                      RDMA_QP_AMBIG_MODIFY, RDMA_QP_AMBIG_DELETE,
                                      RDMA_QP_AMBIG_OCC_FLUSH}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP recovery enum is invalid");
    if (ambiguous_operation == RDMA_QP_AMBIG_OCC_FLUSH) begin
      if (!(ambiguous_role inside {RDMA_QUEUE_ROLE_QP_SQ_RING,
                                   RDMA_QUEUE_ROLE_QP_SQ_PD,
                                   RDMA_QUEUE_ROLE_QP_RQ_PD}))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT, "QP OCC ambiguity role is invalid"
        );
    end
    else if (ambiguous_role != RDMA_QUEUE_ROLE_QP_SQ_RING)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "non-OCC QP recovery uses a non-canonical ambiguity role"
      );
    preprogram_publication =
      intent == RDMA_QP_RECOVER_CREATE_ROLLBACK &&
      ambiguous_operation == RDMA_QP_AMBIG_NONE &&
      ambiguous_ticket == null && prior_qpc == null &&
      candidate_qpc == null && query_mapping == null;
    if (preprogram_publication) begin
      status = rdma_qp_partial_plan_authority(
        qp_plan, recovery_owner, recovery_qp_h
      );
      if (!status.ok()) return status;
      status = rdma_qp_partial_plan_status(
        qp_plan, recovery_owner, recovery_qp_h
      );
      if (!status.ok()) return status;
      if ((context_ref == null) != (qp_plan.context_ref == null))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "partial QP recovery context authority is split"
        );
      if (context_ref != null) begin
        status = rdma_control_nested_status(
          context_ref.validate(), "QP partial recovery context validation"
        );
        if (!status.ok()) return status;
        if (!rdma_qp_recovery_context_equivalent(context_ref,
                                                  qp_plan.context_ref))
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "partial QP recovery context does not equal plan authority"
          );
      end
      for (int unsigned i = 0; i < RDMA_QUEUE_ROLE_QP_SQ_RING; i++) begin
        if (role_complete[i])
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "partial QP recovery progress uses a legacy queue role"
          );
      end
      if (qp_plan.rq_source_h != null &&
          (role_complete[RDMA_QUEUE_ROLE_QP_RQ_RING] ||
           role_complete[RDMA_QUEUE_ROLE_QP_RQ_PD]))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "partial SRQ-backed QP recovery has private RQ progress"
        );
      if (qp_plan.transport != RDMA_TRANSPORT_URC &&
          (role_complete[RDMA_QUEUE_ROLE_QP_URC_RSQ] ||
           role_complete[RDMA_QUEUE_ROLE_QP_URC_RDSQ] ||
           role_complete[RDMA_QUEUE_ROLE_QP_URC_DSQ]))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "partial non-URC QP recovery has URC backing progress"
        );
      if (create_opcode == null || modify_opcode == null ||
          delete_opcode == null || query_opcode == null || occ_opcode == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "partial QP recovery opcode authority is incomplete"
        );
      status = rdma_control_nested_status(
        create_opcode.validate(), "QP create opcode validation"
      );
      if (!status.ok())
        return status;
      status = rdma_control_nested_status(
        modify_opcode.validate(), "QP modify opcode validation"
      );
      if (!status.ok())
        return status;
      status = rdma_control_nested_status(
        delete_opcode.validate(), "QP delete opcode validation"
      );
      if (!status.ok())
        return status;
      status = rdma_control_nested_status(
        query_opcode.validate(), "QP query opcode validation"
      );
      if (!status.ok())
        return status;
      status = rdma_control_nested_status(
        occ_opcode.validate(), "QP OCC opcode validation"
      );
      if (!status.ok())
        return status;
      if (staging_mapping != null) begin
        status = rdma_qp_recovery_mapping_status(
          staging_mapping, recovery_owner, recovery_qp_h,
          "partial QP recovery staging"
        );
        if (!status.ok()) return status;
      end
      if (query_mapping_recovery_only)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "partial QP recovery cannot retain query-only authority"
        );
      return rdma_status::success();
    end
    if (qp_plan == null || context_ref == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "QP recovery authority is incomplete");
    status = rdma_control_nested_status(
      context_ref.validate(), "QP recovery context validation"
    );
    if (!status.ok())
      return status;
    if (context_ref.resource_kind != RDMA_RESOURCE_QP)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "QP recovery context invalid");
    if (!rdma_qp_recovery_context_equivalent(context_ref,
                                              qp_plan.context_ref))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP recovery context does not equal the plan context authority"
      );
    for (int unsigned i = 0; i < RDMA_QUEUE_ROLE_QP_SQ_RING; i++) begin
      if (role_complete[i])
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "QP recovery progress uses a legacy queue role"
        );
    end
    if (qp_plan.rq_source_h != null &&
        (role_complete[RDMA_QUEUE_ROLE_QP_RQ_RING] ||
         role_complete[RDMA_QUEUE_ROLE_QP_RQ_PD]))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "SRQ-backed QP recovery has private RQ progress"
      );
    if (qp_plan.transport != RDMA_TRANSPORT_URC &&
        (role_complete[RDMA_QUEUE_ROLE_QP_URC_RSQ] ||
         role_complete[RDMA_QUEUE_ROLE_QP_URC_RDSQ] ||
         role_complete[RDMA_QUEUE_ROLE_QP_URC_DSQ]))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "non-URC QP recovery has URC backing progress"
      );
    if (!rdma_deep_copy#(rdma_qp_backing_plan)::try_of(qp_plan, validation_plan))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "QP recovery plan clone failed");
    // 进度位只能由对应 ref 授权；缺失的可选 SQ-SGB 不能伪造完成进度。
    status = rdma_qp_recovery_ref_status(
      validation_plan.sq_ref,
      role_complete[RDMA_QUEUE_ROLE_QP_SQ_RING], "QP recovery SQ"
    );
    if (!status.ok()) return status;
    if (validation_plan.sq_sgb_ref != null) begin
      status = rdma_qp_recovery_ref_status(
        validation_plan.sq_sgb_ref,
        role_complete[RDMA_QUEUE_ROLE_QP_SQ_SGB], "QP recovery SQ SGB"
      );
      if (!status.ok()) return status;
    end else if (role_complete[RDMA_QUEUE_ROLE_QP_SQ_SGB]) begin
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "QP recovery SQ SGB progress has no authority");
    end
    status = rdma_qp_recovery_ref_status(
      validation_plan.sq_pd_ref,
      role_complete[RDMA_QUEUE_ROLE_QP_SQ_PD], "QP recovery SQ PD"
    );
    if (!status.ok()) return status;
    if (validation_plan.rq_source_h == null) begin
      status = rdma_qp_recovery_ref_status(
        validation_plan.rq_ref,
        role_complete[RDMA_QUEUE_ROLE_QP_RQ_RING], "QP recovery RQ"
      );
      if (!status.ok()) return status;
      status = rdma_qp_recovery_ref_status(
        validation_plan.rq_pd_ref,
        role_complete[RDMA_QUEUE_ROLE_QP_RQ_PD], "QP recovery RQ PD"
      );
      if (!status.ok()) return status;
    end
    foreach (validation_plan.urc_refs[i]) begin
      status = rdma_qp_recovery_ref_status(
        validation_plan.urc_refs[i],
        role_complete[validation_plan.urc_refs[i].role], "QP recovery URC"
      );
      if (!status.ok()) return status;
    end
    // 先验证 plan 的完整几何，再验证每个 mapping/segment 的 Function/QP owner。
    status = rdma_control_nested_status(
      validation_plan.validate(), "QP recovery plan validation"
    );
    if (!status.ok()) return status;
    if (qp_plan.sq_ref == null || qp_plan.sq_ref.mapping == null ||
        qp_plan.sq_ref.mapping.owner_h == null ||
        qp_plan.sq_ref.mapping.owner_h.kind != RDMA_RESOURCE_QP)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "QP recovery registry owner is missing");
    recovery_qp_h = qp_plan.sq_ref.mapping.owner_h;
    status = rdma_handle_owner_status(recovery_qp_h, context_ref.owner);
    if (!status.ok()) return status;
    status = rdma_qp_mapping_authority_status(
      validation_plan.sq_ref, context_ref.owner, recovery_qp_h,
      "QP recovery SQ"
    );
    if (!status.ok()) return status;
    if (validation_plan.sq_sgb_ref != null) begin
      status = rdma_qp_mapping_authority_status(
        validation_plan.sq_sgb_ref, context_ref.owner, recovery_qp_h,
        "QP recovery SQ SGB"
      );
      if (!status.ok()) return status;
    end
    status = rdma_qp_mapping_authority_status(
      validation_plan.sq_pd_ref, context_ref.owner, recovery_qp_h,
      "QP recovery SQ PD"
    );
    if (!status.ok()) return status;
    if (validation_plan.rq_source_h == null) begin
      status = rdma_qp_mapping_authority_status(
        validation_plan.rq_ref, context_ref.owner, recovery_qp_h,
        "QP recovery RQ"
      );
      if (!status.ok()) return status;
      status = rdma_qp_mapping_authority_status(
        validation_plan.rq_pd_ref, context_ref.owner, recovery_qp_h,
        "QP recovery RQ PD"
      );
      if (!status.ok()) return status;
    end
    else begin
      status = rdma_handle_owner_status(validation_plan.rq_source_h,
                                        context_ref.owner);
      if (!status.ok()) return status;
    end
    foreach (validation_plan.urc_refs[i]) begin
      status = rdma_qp_mapping_authority_status(
        validation_plan.urc_refs[i], context_ref.owner, recovery_qp_h,
        "QP recovery URC"
      );
      if (!status.ok()) return status;
    end
    if ((intent == RDMA_QP_RECOVER_MODIFY_RECONCILE &&
         !(ambiguous_operation inside {RDMA_QP_AMBIG_NONE,
                                        RDMA_QP_AMBIG_MODIFY})) ||
        (intent == RDMA_QP_RECOVER_NORMAL_DESTROY &&
         ambiguous_operation == RDMA_QP_AMBIG_CREATE))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP recovery intent and ambiguous operation do not match"
      );
    if (ambiguous_operation == RDMA_QP_AMBIG_OCC_FLUSH) begin
      if (!(intent inside {RDMA_QP_RECOVER_CREATE_ROLLBACK,
                           RDMA_QP_RECOVER_NORMAL_DESTROY}))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "QP OCC ambiguity is not valid for this recovery intent"
        );
      if ((!qp_plan.cleanup_complete &&
           ambiguous_role != RDMA_QUEUE_ROLE_QP_SQ_RING) ||
          (qp_plan.cleanup_complete && !qp_plan.sq_pd_flush_complete &&
           ambiguous_role != RDMA_QUEUE_ROLE_QP_SQ_PD) ||
          (qp_plan.cleanup_complete && qp_plan.sq_pd_flush_complete &&
           qp_plan.rq_source_h == null && !qp_plan.rq_pd_flush_complete &&
           ambiguous_role != RDMA_QUEUE_ROLE_QP_RQ_PD) ||
          (qp_plan.cleanup_complete && qp_plan.sq_pd_flush_complete &&
           (qp_plan.rq_source_h != null || qp_plan.rq_pd_flush_complete)))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "QP OCC ambiguity is not the first incomplete flush"
        );
    end
    if (intent == RDMA_QP_RECOVER_MODIFY_RECONCILE &&
        (prior_qpc == null || candidate_qpc == null))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "modify recovery lacks prior or candidate QPC authority"
      );
    if (intent == RDMA_QP_RECOVER_NORMAL_DESTROY && prior_qpc == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "destroy recovery lacks prior QPC authority");
    if (intent == RDMA_QP_RECOVER_CREATE_ROLLBACK &&
        ambiguous_operation != RDMA_QP_AMBIG_NONE && candidate_qpc == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "ambiguous create rollback lacks candidate QPC authority"
      );
    if (prior_qpc != null) begin
      status = rdma_control_nested_status(
        prior_qpc.validate(), "prior QPC validation"
      );
      if (!status.ok()) return status;
      if (prior_qpc.qp_h == null ||
          prior_qpc.qp_h.kind != RDMA_RESOURCE_QP)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "prior QPC does not belong to the recovered QP"
        );
      status = rdma_handle_owner_status(prior_qpc.qp_h, context_ref.owner);
      if (!status.ok()) return status;
      if (prior_qpc.qp_h.object_id != context_ref.local_id)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "prior QPC local QPN does not match the recovery context"
        );
    end
    if (candidate_qpc != null) begin
      status = rdma_control_nested_status(
        candidate_qpc.validate(), "candidate QPC validation"
      );
      if (!status.ok()) return status;
      if (candidate_qpc.qp_h == null ||
          candidate_qpc.qp_h.kind != RDMA_RESOURCE_QP)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "candidate QPC does not belong to the recovered QP"
        );
      status = rdma_handle_owner_status(candidate_qpc.qp_h,
                                        context_ref.owner);
      if (!status.ok()) return status;
      if (candidate_qpc.qp_h.object_id != context_ref.local_id)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "candidate QPC local QPN does not match the recovery context"
        );
    end
    if (create_opcode == null || modify_opcode == null ||
        delete_opcode == null || query_opcode == null || occ_opcode == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "QP recovery opcode authority is incomplete");
    status = rdma_control_nested_status(
      create_opcode.validate(), "QP create opcode validation"
    );
    if (!status.ok())
      return status;
    status = rdma_control_nested_status(
      modify_opcode.validate(), "QP modify opcode validation"
    );
    if (!status.ok())
      return status;
    status = rdma_control_nested_status(
      delete_opcode.validate(), "QP delete opcode validation"
    );
    if (!status.ok())
      return status;
    status = rdma_control_nested_status(
      query_opcode.validate(), "QP query opcode validation"
    );
    if (!status.ok())
      return status;
    status = rdma_control_nested_status(
      occ_opcode.validate(), "QP OCC opcode validation"
    );
    if (!status.ok())
      return status;
    if (ambiguous_operation != RDMA_QP_AMBIG_NONE &&
        ambiguous_ticket == null && !has_pending_hardware_step)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "ambiguous QP recovery lacks ticket");
    if (ambiguous_operation == RDMA_QP_AMBIG_NONE &&
        ambiguous_ticket != null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "unambiguous QP recovery carries an ambiguous ticket"
      );
    if (ambiguous_ticket != null) begin
      if (ambiguous_ticket.function_h == null ||
          !ambiguous_ticket.function_h.same_instance(context_ref.owner))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "ambiguous QP recovery ticket Function does not match"
        );
      status = rdma_control_nested_status(
        ambiguous_ticket.validate(), "ambiguous QP recovery ticket validation"
      );
      if (!status.ok())
        return status;
      case (ambiguous_operation)
        RDMA_QP_AMBIG_CREATE:
          if (!rdma_qp_recovery_opcode_equivalent(
                ambiguous_ticket.opcode_key, create_opcode
              ))
            return rdma_status::make(
              RDMA_SC_INVALID_STATE,
              "ambiguous QP create ticket opcode does not match"
            );
        RDMA_QP_AMBIG_MODIFY:
          if (!rdma_qp_recovery_opcode_equivalent(
                ambiguous_ticket.opcode_key, modify_opcode
              ))
            return rdma_status::make(
              RDMA_SC_INVALID_STATE,
              "ambiguous QP modify ticket opcode does not match"
            );
        RDMA_QP_AMBIG_DELETE:
          if (!rdma_qp_recovery_opcode_equivalent(
                ambiguous_ticket.opcode_key, delete_opcode
              ))
            return rdma_status::make(
              RDMA_SC_INVALID_STATE,
              "ambiguous QP delete ticket opcode does not match"
            );
        RDMA_QP_AMBIG_OCC_FLUSH:
          if (!rdma_qp_recovery_opcode_equivalent(
                ambiguous_ticket.opcode_key, occ_opcode
              ))
            return rdma_status::make(
              RDMA_SC_INVALID_STATE,
              "ambiguous QP OCC ticket opcode does not match"
            );
        default:;
      endcase
    end
    // CREATE rollback and MODIFY reconciliation retain a staging allocation;
    // a destroy-time ERROR transition is a state-only QPC_MODIFY and has no
    // staging mapping to retain.
    if (ambiguous_operation == RDMA_QP_AMBIG_CREATE ||
        (ambiguous_operation == RDMA_QP_AMBIG_MODIFY &&
         intent != RDMA_QP_RECOVER_NORMAL_DESTROY &&
         (staging_mapping != null || ambiguous_ticket != null))) begin
      status = rdma_qp_recovery_mapping_status(
        staging_mapping, context_ref.owner, recovery_qp_h,
        "QP recovery staging"
      );
      if (!status.ok()) return status;
    end
    else if (staging_mapping != null) begin
      status = rdma_qp_recovery_mapping_status(
        staging_mapping, context_ref.owner, recovery_qp_h,
        "QP recovery staging"
      );
      if (!status.ok()) return status;
    end
    // An ambiguity-free MODIFY record must retain a query buffer for the
    // final reconciliation proof.  During an unresolved ticket ambiguity the
    // allocation may legitimately be unavailable; recovery will provision a
    // fresh buffer before attempting QPC_QUERY.
    if (intent == RDMA_QP_RECOVER_MODIFY_RECONCILE &&
        ambiguous_operation == RDMA_QP_AMBIG_NONE && query_mapping == null &&
        !has_pending_hardware_step)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "modify recovery lacks query mapping"
      );
    // A query mapping is normally retained for ambiguous MODIFY recovery.  If
    // its allocation itself failed after returning a non-null malformed
    // mapping, retain it as opaque release-only authority and never let it
    // reach QPC_QUERY construction.
    if (query_mapping_recovery_only) begin
      if (!(ambiguous_operation inside {RDMA_QP_AMBIG_NONE,
                                        RDMA_QP_AMBIG_MODIFY}) ||
          query_mapping == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "QP query-only recovery authority is out of order"
        );
      status = rdma_qp_recovery_opaque_mapping_status(
        query_mapping, context_ref.owner, recovery_qp_h,
        "QP recovery query-only"
      );
      if (!status.ok()) return status;
      // Once the modify ambiguity has been reconciled, the malformed query
      // mapping remains in the record only as proof that its opaque release
      // completed.  It must not be accepted in an ambiguity-free record while
      // the adapter still reports an incomplete release.
      if (ambiguous_operation == RDMA_QP_AMBIG_NONE) begin
        bit query_release_complete;
        status = query_mapping.release_completion_status(
          query_release_complete
        );
        if (status == null || !status.ok() || !query_release_complete)
          return status == null ? rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "QP query-only release completion query returned null"
          ) : status.ok() ? rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            "QP query-only release is incomplete"
          ) : status;
      end
    end
    else if (query_mapping != null) begin
      status = rdma_qp_recovery_mapping_status(
        query_mapping, context_ref.owner, recovery_qp_h,
        "QP recovery query"
      );
      if (!status.ok()) return status;
    end
    if (query_presence_known &&
        !(query_presence inside {RDMA_HW_PRESENCE_PRESENT,
                                 RDMA_HW_PRESENCE_ABSENT}))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP recovery query presence is invalid"
      );
    return rdma_status::success();
  endfunction

  // 功能：将 rhs 中 rdma_qp_recovery_state 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（QP recovery copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_qp_recovery_state r;
    uvm_object c;
    super.do_copy(rhs);
    if (!$cast(r, rhs)) `uvm_fatal("RDMA_COPY_TYPE", "QP recovery copy mismatch")
    intent = r.intent;
    ambiguous_operation = r.ambiguous_operation;
    ambiguous_role = r.ambiguous_role;
    role_complete = r.role_complete;
    prior_qpc = null; candidate_qpc = null; qp_plan = null; context_ref = null;
    staging_mapping = null; query_mapping = null;
    query_presence_known = r.query_presence_known;
    query_presence = r.query_presence;
    query_mapping_recovery_only = r.query_mapping_recovery_only;
    has_pending_hardware_step = r.has_pending_hardware_step;
    error_modify_complete = r.error_modify_complete;
    delete_complete = r.delete_complete;
    if (r.prior_qpc != null) begin c = r.prior_qpc.clone(); if (!$cast(prior_qpc, c)) `uvm_fatal("RDMA_COPY_TYPE", "prior QPC clone failure") end
    if (r.candidate_qpc != null) begin c = r.candidate_qpc.clone(); if (!$cast(candidate_qpc, c)) `uvm_fatal("RDMA_COPY_TYPE", "candidate QPC clone failure") end
    if (r.qp_plan != null) begin c = r.qp_plan.clone(); if (!$cast(qp_plan, c)) `uvm_fatal("RDMA_COPY_TYPE", "QP plan clone failure") end
    if (r.context_ref != null) begin c = r.context_ref.clone(); if (!$cast(context_ref, c)) `uvm_fatal("RDMA_COPY_TYPE", "QP context clone failure") end
    if (r.staging_mapping != null) begin c = r.staging_mapping.clone(); if (!$cast(staging_mapping, c)) `uvm_fatal("RDMA_COPY_TYPE", "staging mapping clone failure") end
    if (r.query_mapping != null) begin c = r.query_mapping.clone(); if (!$cast(query_mapping, c)) `uvm_fatal("RDMA_COPY_TYPE", "query mapping clone failure") end
    create_opcode = rdma_cmq_clone_opcode_key_value(r.create_opcode, "QP recovery create");
    modify_opcode = rdma_cmq_clone_opcode_key_value(r.modify_opcode, "QP recovery modify");
    delete_opcode = rdma_cmq_clone_opcode_key_value(r.delete_opcode, "QP recovery delete");
    query_opcode = rdma_cmq_clone_opcode_key_value(r.query_opcode, "QP recovery query");
    occ_opcode = rdma_cmq_clone_opcode_key_value(r.occ_opcode, "QP recovery OCC");
    ambiguous_ticket = rdma_cmq_clone_ticket_value(r.ambiguous_ticket, "QP recovery");
  endfunction
endclass

class rdma_recovery_record extends uvm_object;
  `uvm_object_utils(rdma_recovery_record)

  rdma_handle resource_h;
  rdma_hw_presence_e hardware_presence;
  rdma_control_step_e completed_steps[$];
  rdma_control_step_e pending_steps[$];
  rdma_backing_ref backing_refs[$];
  rdma_hmc_ref hmc_refs[$];
  rdma_cmq_ticket ambiguous_ticket;
  rdma_status primary_status;
  rdma_status rollback_statuses[$];
  bit queue_recovery_valid;
  rdma_queue_recovery_intent_e queue_intent;
  rdma_queue_ambiguous_operation_e ambiguous_queue_operation;
  rdma_queue_backing_role_e ambiguous_role;
  rdma_cmq_opcode_key queue_create_opcode;
  rdma_cmq_opcode_key queue_delete_opcode;
  rdma_cmq_opcode_key queue_query_opcode;
  rdma_queue_backing_plan queue_plan;
  bit qp_recovery_valid;
  rdma_qp_recovery_state qp_recovery;

  // 功能：构造 rdma_recovery_record，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：resource_h=null；hardware_presence=RDMA_HW_PRESENCE_UNKNOWN；ambiguous_ticket=null；primary_status=null；queue_recovery_valid=1'b0；queue_intent=RDMA_QUEUE_RECOVER_CREATE_ROLLBACK；ambiguous_queue_operation=RDMA_QUEUE_AMBIG_NONE；ambiguous_role=RDMA_QUEUE_ROLE_CQ_RING；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_recovery_record 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_recovery_record");
    super.new(name);
    resource_h = null;
    hardware_presence = RDMA_HW_PRESENCE_UNKNOWN;
    ambiguous_ticket = null;
    primary_status = null;
    queue_recovery_valid = 1'b0;
    queue_intent = RDMA_QUEUE_RECOVER_CREATE_ROLLBACK;
    ambiguous_queue_operation = RDMA_QUEUE_AMBIG_NONE;
    ambiguous_role = RDMA_QUEUE_ROLE_CQ_RING;
    queue_create_opcode = null;
    queue_delete_opcode = null;
    queue_query_opcode = null;
    queue_plan = null;
    qp_recovery_valid = 1'b0;
    qp_recovery = null;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“recovery resource handle is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、resource_h、hardware_presence、completed_steps、pending_steps、backing_refs、hmc_refs 并使用字段 has_pending_hardware_step、status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“recovery resource handle is null”“recovery hardware presence is invalid”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;
    bit has_pending_hardware_step;

    if (resource_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "recovery resource handle is null");
    if (!(hardware_presence inside {RDMA_HW_PRESENCE_UNKNOWN,
                                    RDMA_HW_PRESENCE_PRESENT,
                                    RDMA_HW_PRESENCE_ABSENT}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "recovery hardware presence is invalid");
    has_pending_hardware_step = 1'b0;
    foreach (completed_steps[i]) begin
      if (!rdma_control_step_valid(completed_steps[i]))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "recovery completed step is invalid");
    end
    foreach (pending_steps[i]) begin
      if (!rdma_control_step_valid(pending_steps[i]))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "recovery pending step is invalid");
      if (rdma_control_step_is_hardware(pending_steps[i]))
        has_pending_hardware_step = 1'b1;
    end
    foreach (backing_refs[i]) begin
      if (backing_refs[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "recovery backing reference is null");
      status = rdma_status::nonnull(
        backing_refs[i].validate(),
        "recovery backing validation returned null"
      );
      if (!status.ok())
        return status;
    end
    foreach (hmc_refs[i]) begin
      if (hmc_refs[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "recovery HMC reference is null");
      status = rdma_status::nonnull(
        hmc_refs[i].validate(),
        "recovery HMC validation returned null"
      );
      if (!status.ok())
        return status;
    end
    if (ambiguous_ticket != null) begin
      status = rdma_status::nonnull(
        ambiguous_ticket.validate(),
        "recovery ticket validation returned null"
      );
      if (!status.ok())
        return status;
    end
    if (primary_status == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "recovery primary status is null");
    foreach (rollback_statuses[i]) begin
      if (rollback_statuses[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "recovery rollback status is null");
    end
    if (hardware_presence == RDMA_HW_PRESENCE_UNKNOWN &&
        ambiguous_ticket == null && !has_pending_hardware_step &&
        !(qp_recovery_valid && qp_recovery != null &&
          (qp_recovery.ambiguous_ticket != null ||
           qp_recovery.has_pending_hardware_step)))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "unknown hardware presence lacks an ambiguous ticket or hardware step"
      );
    if (resource_h.kind == RDMA_RESOURCE_MR && queue_recovery_valid)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MR recovery cannot use queue schema");
    if (resource_h.kind == RDMA_RESOURCE_QP && !qp_recovery_valid)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "QP recovery lacks QP schema");
    if (qp_recovery_valid) begin
      if (resource_h.kind != RDMA_RESOURCE_QP || qp_recovery == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "QP recovery resource/schema mismatch");
      status = rdma_control_nested_status(
        qp_recovery.validate(), "nested QP recovery validation"
      );
      if (!status.ok())
        return status;
      if (qp_recovery.qp_plan == null ||
          qp_recovery.qp_plan.sq_ref == null ||
          qp_recovery.qp_plan.sq_ref.mapping == null ||
          qp_recovery.qp_plan.sq_ref.mapping.owner_h == null ||
          !resource_h.same_instance(
            qp_recovery.qp_plan.sq_ref.mapping.owner_h
          ))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "QP recovery record resource does not match nested authority"
        );
    end
    if (queue_recovery_valid) begin
      if (!(resource_h.kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                    RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ}))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "queue recovery resource kind is invalid");
      if (!(queue_intent inside {RDMA_QUEUE_RECOVER_CREATE_ROLLBACK,
                                 RDMA_QUEUE_RECOVER_NORMAL_DESTROY}) ||
          !(ambiguous_queue_operation inside {RDMA_QUEUE_AMBIG_NONE,
                                               RDMA_QUEUE_AMBIG_CREATE,
                                               RDMA_QUEUE_AMBIG_DELETE,
                                               RDMA_QUEUE_AMBIG_OCC_FLUSH}) ||
          !rdma_queue_role_is_payload(ambiguous_role) &&
          !rdma_queue_role_is_pd(ambiguous_role))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "queue recovery enum value is invalid");
      if (queue_plan == null || queue_plan.resource_kind != resource_h.kind)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "queue recovery plan kind does not match");
      status = rdma_control_nested_status(
        queue_plan.validate(), "queue recovery plan validation"
      );
      if (!status.ok())
        return status;
      if (queue_create_opcode == null || queue_delete_opcode == null ||
          queue_query_opcode == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "queue recovery opcode key is null");
      status = rdma_control_nested_status(
        queue_create_opcode.validate(), "queue create opcode validation"
      );
      if (!status.ok())
        return status;
      status = rdma_control_nested_status(
        queue_delete_opcode.validate(), "queue delete opcode validation"
      );
      if (!status.ok())
        return status;
      status = rdma_control_nested_status(
        queue_query_opcode.validate(), "queue query opcode validation"
      );
      if (!status.ok())
        return status;
      if (ambiguous_queue_operation == RDMA_QUEUE_AMBIG_OCC_FLUSH &&
          (!rdma_queue_role_is_pd(ambiguous_role) || ambiguous_ticket == null))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "ambiguous queue OCC flush requires a PD role and ticket"
        );
    end
    return rdma_status::success();
  endfunction

  // 功能：将 rhs 中 rdma_recovery_record 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（recovery record copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_recovery_record rhs_record;
    rdma_backing_ref cloned_backing_ref;
    rdma_hmc_ref cloned_hmc_ref;

    super.do_copy(rhs);
    if (!$cast(rhs_record, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "recovery record copy mismatch")
    resource_h = rdma_clone_handle_value(rhs_record.resource_h,
                                         "recovery record");
    hardware_presence = rhs_record.hardware_presence;
    completed_steps = rhs_record.completed_steps;
    pending_steps = rhs_record.pending_steps;
    backing_refs.delete();
    foreach (rhs_record.backing_refs[i]) begin
      if (rhs_record.backing_refs[i] == null) begin
        backing_refs.push_back(null);
      end
      else begin
        cloned_backing_ref = rdma_deep_copy#(rdma_backing_ref)::of(
          rhs_record.backing_refs[i], "recovery backing reference clone mismatch");
        backing_refs.push_back(cloned_backing_ref);
      end
    end
    hmc_refs.delete();
    foreach (rhs_record.hmc_refs[i]) begin
      if (rhs_record.hmc_refs[i] == null) begin
        hmc_refs.push_back(null);
      end
      else begin
        cloned_hmc_ref = rdma_deep_copy#(rdma_hmc_ref)::of(
          rhs_record.hmc_refs[i], "recovery HMC reference clone mismatch");
        hmc_refs.push_back(cloned_hmc_ref);
      end
    end
    ambiguous_ticket = rdma_cmq_clone_ticket_value(
      rhs_record.ambiguous_ticket, "recovery record"
    );
    primary_status = rdma_cmq_clone_status_value(rhs_record.primary_status);
    rollback_statuses.delete();
    foreach (rhs_record.rollback_statuses[i])
      rollback_statuses.push_back(
        rdma_cmq_clone_status_value(rhs_record.rollback_statuses[i])
      );
    queue_recovery_valid = rhs_record.queue_recovery_valid;
    queue_intent = rhs_record.queue_intent;
    ambiguous_queue_operation = rhs_record.ambiguous_queue_operation;
    ambiguous_role = rhs_record.ambiguous_role;
    queue_create_opcode = rdma_cmq_clone_opcode_key_value(
      rhs_record.queue_create_opcode, "recovery queue create"
    );
    queue_delete_opcode = rdma_cmq_clone_opcode_key_value(
      rhs_record.queue_delete_opcode, "recovery queue delete"
    );
    queue_query_opcode = rdma_cmq_clone_opcode_key_value(
      rhs_record.queue_query_opcode, "recovery queue query"
    );
    queue_plan = rdma_deep_copy#(rdma_queue_backing_plan)::of(
      rhs_record.queue_plan, "recovery queue plan clone mismatch");
    qp_recovery_valid = rhs_record.qp_recovery_valid;
    qp_recovery = rdma_deep_copy#(rdma_qp_recovery_state)::of(
      rhs_record.qp_recovery, "recovery QP state clone mismatch");
  endfunction
endclass

// 设计说明：control plane 与 queue lifecycle executor 共用同一组恢复阶段账本操作；
//   集中在 model 层的无状态函数里，避免两个 owner 各维护一份扫描/去重规则。
//   所有函数对 null recovery/result 安全，只修改传入记录本身。

// 功能：判断 step 是否已记入 recovery.completed_steps。
// 输入/输出及副作用：recovery、step 只读；返回命中位，不修改记录。
// 失败/边界：recovery 为 null 返回 0。
function automatic bit rdma_recovery_step_completed(
  rdma_recovery_record recovery,
  rdma_control_step_e step
);
  if (recovery == null)
    return 1'b0;
  foreach (recovery.completed_steps[i])
    if (recovery.completed_steps[i] == step)
      return 1'b1;
  return 1'b0;
endfunction

// 功能：判断 step 是否仍在 recovery.pending_steps 中等待执行。
// 输入/输出及副作用：recovery、step 只读；返回命中位，不修改记录。
// 失败/边界：recovery 为 null 返回 0。
function automatic bit rdma_recovery_step_pending(
  rdma_recovery_record recovery,
  rdma_control_step_e step
);
  if (recovery == null)
    return 1'b0;
  foreach (recovery.pending_steps[i])
    if (recovery.pending_steps[i] == step)
      return 1'b1;
  return 1'b0;
endfunction

// 功能：从 pending_steps 删除 step 的全部出现。
// 输入/输出及副作用：原地修改 recovery.pending_steps，其余字段不变。
// 失败/边界：recovery 为 null 或 step 不存在时为空操作。
function automatic void rdma_recovery_remove_pending(
  rdma_recovery_record recovery,
  rdma_control_step_e step
);
  if (recovery == null)
    return;
  for (int i = int'(recovery.pending_steps.size()) - 1; i >= 0; i--)
    if (recovery.pending_steps[i] == step)
      recovery.pending_steps.delete(i);
endfunction

// 功能：从 completed_steps 删除 step 的第一次出现，用于恢复回退已完成阶段。
// 输入/输出及副作用：原地修改 recovery.completed_steps，其余字段不变。
// 失败/边界：recovery 为 null 或 step 不存在时为空操作。
function automatic void rdma_recovery_remove_completed(
  rdma_recovery_record recovery,
  rdma_control_step_e step
);
  if (recovery == null)
    return;
  foreach (recovery.completed_steps[i]) begin
    if (recovery.completed_steps[i] == step) begin
      recovery.completed_steps.delete(i);
      return;
    end
  end
endfunction

// 功能：把尚未完成且未排队的 step 追加到 pending_steps 末尾。
// 输入/输出及副作用：可能向 recovery.pending_steps 追加一项。
// 失败/边界：recovery 为 null、step 已完成或已排队时为空操作（幂等）。
function automatic void rdma_recovery_queue_step(
  rdma_recovery_record recovery,
  rdma_control_step_e step
);
  if (recovery == null || rdma_recovery_step_completed(recovery, step) ||
      rdma_recovery_step_pending(recovery, step))
    return;
  recovery.pending_steps.push_back(step);
endfunction

// 功能：把 step 从 pending 移到 completed。
// 输入/输出及副作用：删除 pending 中的 step，completed 中不存在时追加。
// 失败/边界：recovery 为 null 时为空操作；重复调用幂等。
function automatic void rdma_recovery_complete_step(
  rdma_recovery_record recovery,
  rdma_control_step_e step
);
  if (recovery == null)
    return;
  rdma_recovery_remove_pending(recovery, step);
  if (!rdma_recovery_step_completed(recovery, step))
    recovery.completed_steps.push_back(step);
endfunction

// 功能：把恢复账本的阶段历史、primary/rollback status 投影到 caller 可见结果。
// 输入/输出及副作用：覆盖 result.completed_steps/primary_status/rollback_statuses，
//   status 均为 detached clone，recovery 只读。
// 失败/边界：recovery 或 result 为 null 时为空操作。
function automatic void rdma_recovery_project_history(
  rdma_recovery_record recovery,
  rdma_control_result result
);
  if (recovery == null || result == null)
    return;
  result.completed_steps = recovery.completed_steps;
  result.primary_status = rdma_cmq_clone_status_value(recovery.primary_status);
  result.rollback_statuses.delete();
  foreach (recovery.rollback_statuses[i])
    result.rollback_statuses.push_back(
      rdma_cmq_clone_status_value(recovery.rollback_statuses[i])
    );
endfunction

// 功能：以 RECOVERY_REQUIRED 发布结果，并把资源终态标记为已知 ERROR。
// 输入/输出及副作用：先投影恢复历史，再写 result.status、final_resource_state、
//   final_resource_state_known 与 recovery_required。
// 失败/边界：result 不得为 null（调用方总是传入已构造结果）；recovery 可为 null。
function automatic void rdma_recovery_publish_required(
  rdma_recovery_record recovery,
  rdma_control_result result,
  string message
);
  rdma_recovery_project_history(recovery, result);
  result.status = rdma_status::make(RDMA_SC_RECOVERY_REQUIRED, message);
  result.final_resource_state = RDMA_RESOURCE_ERROR;
  result.final_resource_state_known = 1'b1;
  result.recovery_required = 1'b1;
endfunction
