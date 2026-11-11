// 目录/层次：integration/project；项目组合配置。
// 职责：直接组合DPU/RDMA/PCIe既有配置，约束运行期唯一可消费DPU策略。
// 依赖：所属runtime package导入类型；不加载参数、不解析拓扑。
// 所有权/生命周期：平台提供并持有三个配置；项目仅借用，整个运行期保持句柄。
class rdma_project_env_cfg extends uvm_object;
  `uvm_object_utils(rdma_project_env_cfg)
  dpu_env_cfg	dpu;
  rdma_env_cfg	rdma;
  pcie_tl_env_config	pcie;
  dpu_function_key_t	functions[$];
  // 每个 RDMA Function 的平台资源/路由授权，和 functions 保持同一快照顺序。
  rdma_dpu_grant	grants[$];
  rdma_hw_plan	hw_plan;

  // 功能：构造尚未绑定平台三种配置的组合对象。
  // 输入/输出及副作用：name传给UVM；所有配置句柄初始为空。
  // 失败/边界：build前必须补齐配置与完整RDMA目录，构造不创建资源。
  extern function new(string	name = "rdma_project_env_cfg");

  // 功能：拒绝无消费者的DPU运行期变化，只允许print_bar_map和verify_readback。
  // 输入/输出及副作用：candidate只读，why指出首个不支持的字段；不修改任何活动对象。
  // 失败/边界：空候选、身份/规模/表/消息/控制或其他策略变化返回假，候选无需伪造runtime_ready。
  extern function bit validate_dpu(dpu_env_cfg	candidate, output string	why);
endclass

// 功能：构造尚未绑定平台三种配置的组合对象。
// 输入/输出及副作用：name传给UVM；所有配置句柄初始为空。
// 失败/边界：build前必须补齐配置与完整RDMA目录，构造不创建资源。
function rdma_project_env_cfg::new(string	name = "rdma_project_env_cfg");
  super.new(name);
  grants.delete();
  hw_plan = rdma_hw_plan::type_id::create("hw_plan");
endfunction

// 功能：拒绝无消费者的DPU运行期变化，只允许print_bar_map和verify_readback。
// 输入/输出及副作用：candidate只读，why指出首个不支持的字段；不修改任何活动对象。
// 失败/边界：空候选、身份/规模/表/消息/控制或其他策略变化返回假，候选无需伪造runtime_ready。
function bit rdma_project_env_cfg::validate_dpu(dpu_env_cfg	candidate, output string	why);
  why = "DPU candidate changed immutable source/topology";
  if (candidate == null || dpu == null || candidate.device_cfg != dpu.device_cfg ||
      candidate.placement_cfg != dpu.placement_cfg || candidate.device_snapshot != dpu.device_snapshot ||
      candidate.resource_snapshot != dpu.resource_snapshot || candidate.bar_map != dpu.bar_map ||
      candidate.hosts != dpu.hosts || candidate.pfs_per_host != dpu.pfs_per_host ||
      candidate.vfs_per_pf != dpu.vfs_per_pf)
    return 0;
  why = "DPU runtime supports only print_bar_map and verify_readback; routing/control consumer unavailable";
  if (candidate.reg_target != dpu.reg_target || candidate.configure_public != dpu.configure_public ||
      candidate.configure_bdf != dpu.configure_bdf || candidate.driver_layouts != dpu.driver_layouts ||
      candidate.qsch_configure_controls != dpu.qsch_configure_controls ||
      candidate.qsch_mode != dpu.qsch_mode || candidate.qsch_mode_offset != dpu.qsch_mode_offset ||
      candidate.qsch_spwrr != dpu.qsch_spwrr || candidate.qsch_tc_weight != dpu.qsch_tc_weight ||
      candidate.platform_controls != dpu.platform_controls || candidate.frozen_controls != dpu.frozen_controls ||
      candidate.messages != dpu.messages || candidate.frozen_messages != dpu.frozen_messages ||
      candidate.frozen_bar_groups != dpu.frozen_bar_groups || candidate.frozen_reg_target != dpu.frozen_reg_target)
    return 0;
  if (candidate.table_layouts.num() != dpu.table_layouts.num())
    return 0;
  foreach (dpu.table_layouts[key])
    if (!candidate.table_layouts.exists(key) || candidate.table_layouts[key] !== dpu.table_layouts[key])
      return 0;
  if (candidate.function_policies.num() != dpu.function_policies.num())
    return 0;
  foreach (dpu.function_policies[key])
    if (!candidate.function_policies.exists(key) || candidate.function_policies[key] !== dpu.function_policies[key])
      return 0;
  if (candidate.vio_policies.num() != dpu.vio_policies.num())
    return 0;
  foreach (dpu.vio_policies[key])
    if (!candidate.vio_policies.exists(key) || candidate.vio_policies[key] !== dpu.vio_policies[key])
      return 0;
  if (candidate.msix_policies.num() != dpu.msix_policies.num())
    return 0;
  foreach (dpu.msix_policies[key])
    if (!candidate.msix_policies.exists(key) || candidate.msix_policies[key] !== dpu.msix_policies[key])
      return 0;
  if (candidate.frozen_layouts.num() != dpu.frozen_layouts.num())
    return 0;
  foreach (dpu.frozen_layouts[key])
    if (!candidate.frozen_layouts.exists(key) || candidate.frozen_layouts[key] !== dpu.frozen_layouts[key])
      return 0;
  if (candidate.frozen_functions.num() != dpu.frozen_functions.num())
    return 0;
  foreach (dpu.frozen_functions[key])
    if (!candidate.frozen_functions.exists(key) || candidate.frozen_functions[key] !== dpu.frozen_functions[key])
      return 0;
  if (candidate.frozen_policies.num() != dpu.frozen_policies.num())
    return 0;
  foreach (dpu.frozen_policies[key])
    if (!candidate.frozen_policies.exists(key) || candidate.frozen_policies[key] !== dpu.frozen_policies[key])
      return 0;
  if (candidate.frozen_msix_policies.num() != dpu.frozen_msix_policies.num())
    return 0;
  foreach (dpu.frozen_msix_policies[key])
    if (!candidate.frozen_msix_policies.exists(key) || candidate.frozen_msix_policies[key] !== dpu.frozen_msix_policies[key])
      return 0;
  if (candidate.services.num() != dpu.services.num())
    return 0;
  foreach (dpu.services[key])
    if (!candidate.services.exists(key) || candidate.services[key] !== dpu.services[key])
      return 0;
  if (candidate.message_templates.num() != dpu.message_templates.num())
    return 0;
  foreach (dpu.message_templates[key]) begin
    if (!candidate.message_templates.exists(key) ||
        candidate.message_templates[key].num() != dpu.message_templates[key].num())
      return 0;
    foreach (dpu.message_templates[key][vector])
      if (!candidate.message_templates[key].exists(vector) ||
          candidate.message_templates[key][vector] !== dpu.message_templates[key][vector])
        return 0;
  end
  why = "";
  return 1;
endfunction
