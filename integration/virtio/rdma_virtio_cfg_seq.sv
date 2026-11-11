// 目录/层次：integration/virtio；共享 DPU 的单一配置 sequence。
// 职责：继承 virtio 的公共表/队列流程，在 VIO 队列准备前增加 RDMA Notify/RNET。
// 依赖：vio_dpu_cfg_seq 和 rdma_project_cfg_seq；复用原有编码、预检和 PCIe 写表方法。
// 所有权/生命周期：只借用 cfg、RC 和各 Host VIO env；失败后资源由平台停机并释放。
class rdma_virtio_cfg_seq extends vio_dpu_cfg_seq;
  `uvm_object_utils(rdma_virtio_cfg_seq)

  dpu_function_key_t rdma_functions[$];
  rdma_dpu_grant rdma_grants[$];
  rdma_hw_plan hw_plan;
  // 关闭时只执行继承的 VIO/DPU 流程，避免 RDMA 预检和 RDMA 表事务。
  bit rdma_enabled;
  protected dpu_cfg_scope rdma_scope;

  // 功能：构造组合配置序列，公共表及 VIO 生命周期由父类负责。
  // 输入/输出及副作用：name 透传；rdma_functions 由项目提供，不创建硬件资源。
  // 失败/边界：rdma_enabled=0 时跳过 RDMA 目录，直接走父类 VIO 流程；开启后空目录仍由预检拒绝。
  function new(string name = "rdma_virtio_cfg_seq");
    super.new(name);
    hw_plan = null;
    rdma_enabled = 0;
  endfunction

  // 功能：先校验完整 RDMA 目录，再执行父类唯一的 AF/BDF/MSI-X/VIO 配置流程。
  // 输入/输出及副作用：借用 cfg 和启动 RC；success/error_msg 沿用父类，不重复写公共表。
  // 失败/边界：RDMA 预检失败时零 MMIO；后续硬件失败沿用父类 fatal，不回滚已发送的写入。
  virtual task body();
    rdma_project_cfg_seq check;
    dpu_cfg_scope bdf_scope;
    dpu_cfg_scope msix_scope;
    bit ok;

    if (!rdma_enabled) begin
      super.body();
      return;
    end
    check = rdma_project_cfg_seq::type_id::create("rdma_preflight");
    check.cfg = cfg;
    check.set_sequencer(m_sequencer);
    check.rdma_functions = rdma_functions;
    check.rdma_grants = rdma_grants;
    check.hw_plan = hw_plan;
    ok = check.preflight(bdf_scope, msix_scope, rdma_scope, error_msg);
    if (!completed_step("rdma_preflight", ok))
      return;
    hw_plan = check.hw_plan;
    super.body();
  endtask

  // 功能：公共表成功后写 RDMA Notify/RNET，再调用 virtio 的真实 ring 准备和导出。
  // 输入/输出及副作用：ok/why 报告首个失败；selection 仍由父 VIO 逻辑发布。
  // 失败/边界：任一 RDMA 写表失败不准备 VIO ring；VIO 准备失败保留其已有清理契约。
  virtual task prepare_queues(output bit ok, output string why);
    if (!rdma_enabled) begin
      super.prepare_queues(ok, why);
      return;
    end
    if (rdma_grants.size() != 0) begin
      configure_hw_plan(ok, why);
      if (!ok)
        return;
    end
    configure_rdma_notify(rdma_scope, ok, why);
    if (!ok)
      return;
    configure_qsch_rnet(rdma_scope, ok, why);
    if (!ok)
      return;
    super.prepare_queues(ok, why);
  endtask

  // 功能：把组合环境的冻结 RDMA plan 写入管理 BAR，再进入 Notify/RNET 和 VIO 队列准备。
  // 输入/输出及副作用：逐项复用父类 write_table_dwords；ok/why 返回首个 PCIe 失败。
  // 失败/边界：无 grant 时不写 plan；plan 未建立、目标越界或任一写失败时不触发 VIO preparation。
  protected task configure_hw_plan(output bit ok, output string why);
    rdma_hw_reg_write plan_writes[$];
    rdma_status status;

    ok = 0;
    why = "RDMA hardware plan is not available";
    if (hw_plan == null)
      return;
    status = hw_plan.validate();
    if (!status.ok()) begin
      why = status.convert2string();
      return;
    end
    hw_plan.list_writes(plan_writes);
    foreach (plan_writes[i]) begin
      write_table_dwords(plan_writes[i].target, plan_writes[i].offset, 4,
                         128'(plan_writes[i].value), ok, why);
      if (!ok)
        return;
    end
    ok = 1;
    why = "";
  endtask
endclass
