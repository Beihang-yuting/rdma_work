// 目录/层次：integration/virtio；平台可直接注册到 Tcl 的独立项目配置 sequence。
// 职责：获取完整 project_env_cfg，按已启用业务选择现有配置流程并发布 RDMA 配置完成状态。
// 依赖：dpu_cfg_seq、project_env_pkg、RDMA/VIO 配置 sequence 和 rdma_aip_pkg。
// 所有权/生命周期：只借用 RC 发布的配置、VIO env 和 AIP target；子 sequence 随本次调用创建，
// 不重新 load_params、分配 grant 或启动驱动，平台须在 start 前完成 reset/readiness。
class project_dut_config_seq extends dpu_cfg_seq;
  `uvm_object_utils(project_dut_config_seq)

  protected project_env_cfg	project_cfg;
  protected rdma_aip_target	rdma_target;
  protected bit			has_vio;
  protected bit			owns_rdma_busy;

  // 功能：构造只负责项目配置编排的空闲 sequence。
  // 输入/输出及副作用：name 传给父类；配置和 target 默认空，尚未占用 RDMA 命令状态。
  // 失败/边界：构造不访问配置或 DUT；启动时才检查 RC 和环境是否同源、空闲。
  extern function new(string	name = "project_dut_config_seq");

  // 功能：从启动 RC 获取同一份项目配置，检查活动 VIO 代及 RDMA 初始化门禁。
  // 输入/输出及副作用：父类获取 dpu_cfg，本类借用 project_cfg；成功时清除 RDMA 配置标志并占用 busy。
  // 失败/边界：缺项目配置、DPU 异源、缺资源快照、活动 VIO 代、缺/异源 AIP target 或已初始化时，
  // 设置 error_msg，body 不发事务，post_start 沿用父类 fatal；关闭 RDMA 时不查询其 registry。
  extern virtual task pre_start();

  // 功能：按冻结 VIO 队列及 RDMA 开关选择唯一配置流程，集中传递已有 Function/grant。
  // 输入/输出及副作用：子 sequence 复用当前 RC/DPU 配置，返回 success/error_msg；只执行开启的业务。
  // 失败/边界：pre_start 拒绝时零事务；子流程失败保留原诊断和已发写入，不继续初始化或发包。
  extern virtual task body();

  // 功能：释放本次 RDMA busy，并仅在全部配置成功后允许 rdma_init。
  // 输入/输出及副作用：更新借用 target 的 configured/busy；错误沿用父类 post_start 报告。
  // 失败/边界：未取得 RDMA busy 时不改 target；失败不发布成功，已发 MMIO 不回滚。
  extern virtual task post_start();

  // 功能：显式取消配置时关闭 RDMA 初始化入口，释放本 sequence 占用的命令 busy。
  // 输入/输出及副作用：UVM kill 调用本回调；保留已发送的硬件写入，configured 置零。
  // 失败/边界：重复取消或未取得 busy 时保持幂等；不替平台回滚表项或恢复 DUT。
  extern virtual function void do_kill();
endclass

// 功能：构造只负责项目配置编排的空闲 sequence。
// 输入/输出及副作用：name 传给父类；配置和 target 默认空，尚未占用 RDMA 命令状态。
// 失败/边界：构造不访问配置或 DUT；启动时才检查 RC 和环境是否同源、空闲。
function project_dut_config_seq::new(string	name = "project_dut_config_seq");
  super.new(name);
endfunction

// 功能：从启动 RC 获取同一份项目配置，检查活动 VIO 代及 RDMA 初始化门禁。
// 输入/输出及副作用：父类获取 dpu_cfg，本类借用 project_cfg；成功时清除 RDMA 配置标志并占用 busy。
// 失败/边界：缺项目配置、DPU 异源、缺资源快照、活动 VIO 代、缺/异源 AIP target 或已初始化时，
// 设置 error_msg，body 不发事务，post_start 沿用父类 fatal；关闭 RDMA 时不查询其 registry。
task project_dut_config_seq::pre_start();
  dpu_vio_qpair_binding_t	pairs[$];
  bit				checked_host[int unsigned];

  super.pre_start();
  project_cfg = null;
  rdma_target = null;
  owns_rdma_busy = 0;
  has_vio = 0;
  if (!uvm_config_db#(project_env_cfg)::get(m_sequencer, "", "project_cfg", project_cfg) ||
      project_cfg == null) begin
    error_msg = "PCIe sequencer has no project_cfg; publish the existing project_env_cfg";
    return;
  end
  if (project_cfg.dpu_cfg != cfg || cfg.resource_snapshot == null) begin
    error_msg = "project_cfg and PCIe dpu_cfg must share the published resource snapshot";
    return;
  end

  cfg.resource_snapshot.list_vio_bindings(pairs);
  has_vio = pairs.size() != 0;
  foreach (pairs[i]) begin
    virtio_net_env	env;
    int unsigned	host;

    host = pairs[i].service_key.function_key.host_id;
    if (checked_host.exists(host))
      continue;
    checked_host[host] = 1;
    if (!uvm_config_db#(virtio_net_env)::get(
          m_sequencer, "", $sformatf("vio_env_h%0d", host), env) ||
        env == null) begin
      error_msg = $sformatf("PCIe sequencer has no vio_env_h%0d", host);
      return;
    end
    if (env.get_external_setup() != null) begin
      error_msg = "release existing VIO generation before dut_config";
      return;
    end
  end

  if (!project_cfg.rdma_enabled)
    return;
  rdma_target = rdma_aip_registry::target;
  if (rdma_target == null) begin
    error_msg = "bind RDMA AIP commands before dut_config";
    return;
  end
  if (rdma_target.env == null || project_cfg.rdma_cfg == null) begin
    error_msg = "RDMA AIP environment or project RDMA configuration is missing";
    return;
  end
  if (rdma_target.env.cfg != project_cfg.rdma_cfg ||
      rdma_target.busy || rdma_target.init_attempted) begin
    error_msg = "dut_config requires the same idle RDMA target before initialization";
    return;
  end
  rdma_target.mark_configured(0);
  rdma_target.busy = 1;
  owns_rdma_busy = 1;
endtask

// 功能：按冻结 VIO 队列及 RDMA 开关选择唯一配置流程，集中传递已有 Function/grant。
// 输入/输出及副作用：子 sequence 复用当前 RC/DPU 配置，返回 success/error_msg；只执行开启的业务。
// 失败/边界：pre_start 拒绝时零事务；子流程失败保留原诊断和已发写入，不继续初始化或发包。
task project_dut_config_seq::body();
  dpu_cfg_seq	config_seq;

  if (error_msg != "")
    return;
  if (project_cfg.rdma_enabled && has_vio) begin
    rdma_virtio_cfg_seq	merged_seq;

    merged_seq = rdma_virtio_cfg_seq::type_id::create("rdma_vio_config");
    merged_seq.rdma_enabled = 1;
    merged_seq.rdma_functions = project_cfg.rdma_functions;
    merged_seq.rdma_grants = project_cfg.rdma_cfg.grants;
    config_seq = merged_seq;
  end else if (project_cfg.rdma_enabled) begin
    rdma_project_cfg_seq	rdma_seq;

    rdma_seq = rdma_project_cfg_seq::type_id::create("rdma_config");
    rdma_seq.rdma_functions = project_cfg.rdma_functions;
    rdma_seq.rdma_grants = project_cfg.rdma_cfg.grants;
    config_seq = rdma_seq;
  end else begin
    config_seq = vio_dpu_cfg_seq::type_id::create("vio_config");
  end
  config_seq.start(m_sequencer, this);
  success = config_seq.success;
  error_msg = config_seq.error_msg;
endtask

// 功能：释放本次 RDMA busy，并仅在全部配置成功后允许 rdma_init。
// 输入/输出及副作用：更新借用 target 的 configured/busy；错误沿用父类 post_start 报告。
// 失败/边界：未取得 RDMA busy 时不改 target；失败不发布成功，已发 MMIO 不回滚。
task project_dut_config_seq::post_start();
  if (owns_rdma_busy) begin
    rdma_target.mark_configured(success);
    rdma_target.busy = 0;
    owns_rdma_busy = 0;
  end
  super.post_start();
endtask

// 功能：显式取消配置时关闭 RDMA 初始化入口，释放本 sequence 占用的命令 busy。
// 输入/输出及副作用：UVM kill 调用本回调；保留已发送的硬件写入，configured 置零。
// 失败/边界：重复取消或未取得 busy 时保持幂等；不替平台回滚表项或恢复 DUT。
function void project_dut_config_seq::do_kill();
  if (owns_rdma_busy) begin
    rdma_target.mark_configured(0);
    rdma_target.busy = 0;
    owns_rdma_busy = 0;
  end
  super.do_kill();
endfunction
