// 目录/层次：integration/virtio；共享 DPU 的单一配置 sequence。
// 职责：继承 virtio 的公共表/队列流程，在 VIO 队列准备前增加 RDMA Notify/RNET。
// 依赖：vio_dpu_cfg_seq 和 rdma_project_cfg_seq；复用原有编码、预检和 PCIe 写表方法。
// 所有权/生命周期：只借用 cfg、RC 和各 Host VIO env；失败后资源由平台停机并释放。
class rdma_virtio_cfg_seq extends vio_dpu_cfg_seq;
  `uvm_object_utils(rdma_virtio_cfg_seq)

  dpu_function_key_t rdma_functions[$];
  protected dpu_cfg_scope rdma_scope;

  // 功能：构造组合配置序列，公共表及 VIO 生命周期由父类负责。
  // 输入/输出及副作用：name 透传；rdma_functions 由项目提供，不创建硬件资源。
  // 失败/边界：空 RDMA 目录在 body 的预检拒绝，构造本身不发事务。
  function new(string name = "rdma_virtio_cfg_seq");
    super.new(name);
  endfunction

  // 功能：先校验完整 RDMA 目录，再执行父类唯一的 AF/BDF/MSI-X/VIO 配置流程。
  // 输入/输出及副作用：借用 cfg 和启动 RC；success/error_msg 沿用父类，不重复写公共表。
  // 失败/边界：RDMA 预检失败时零 MMIO；后续硬件失败沿用父类 fatal，不回滚已发送的写入。
  virtual task body();
    rdma_project_cfg_seq check;
    dpu_cfg_scope bdf_scope;
    dpu_cfg_scope msix_scope;
    bit ok;

    check = rdma_project_cfg_seq::type_id::create("rdma_preflight");
    check.cfg = cfg;
    check.set_sequencer(m_sequencer);
    check.rdma_functions = rdma_functions;
    ok = check.preflight(bdf_scope, msix_scope, rdma_scope, error_msg);
    if (!completed_step("rdma_preflight", ok))
      return;
    super.body();
  endtask

  // 功能：公共表成功后写 RDMA Notify/RNET，再调用 virtio 的真实 ring 准备和导出。
  // 输入/输出及副作用：ok/why 报告首个失败；selection 仍由父 VIO 逻辑发布。
  // 失败/边界：任一 RDMA 写表失败不准备 VIO ring；VIO 准备失败保留其已有清理契约。
  virtual task prepare_queues(output bit ok, output string why);
    configure_rdma_notify(rdma_scope, ok, why);
    if (!ok)
      return;
    configure_qsch_rnet(rdma_scope, ok, why);
    if (!ok)
      return;
    super.prepare_queues(ok, why);
  endtask
endclass
