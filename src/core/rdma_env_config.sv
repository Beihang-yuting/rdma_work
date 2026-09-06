// 目录：核心执行层 src/core/rdma_env_config.sv。
// 职责：保存 rdma_env 的模式、适配器能力、超时、队列 profile 和 responder 配置。
// 依赖：依赖 rdma_types_pkg、rdma_model_pkg 和 rdma_responder_registry 的值类型；不拥有外部 adapter。
// 所有权与生命周期：配置对象由调用方创建；rdma_env.build_phase 通过 clone 拥有冻结快照，原始对象可独立销毁或修改。

typedef enum bit [1:0] {
  RDMA_ENV_CORE_ONLY  = 2'd0,
  RDMA_ENV_MODEL_ONLY = 2'd1,
  RDMA_ENV_DUT        = 2'd2,
  RDMA_ENV_HYBRID     = 2'd3
} rdma_env_mode_e;

class rdma_env_config extends uvm_object;
  `uvm_object_utils(rdma_env_config)

  rdma_env_mode_e mode;
  int unsigned hardware_version;
  bit pcie_enabled, pcie_required;
  bit host_mem_enabled, host_mem_required;
  bit net_enabled, net_required;
  time operation_timeout;
  rdma_queue_capabilities queue_profile;
  rdma_responder_region responder_regions[$];
  // identity/binding 是可选的 dpu_common 投影；env 只保留 detached snapshot。
  rdma_function_identity function_identity;
  rdma_function_binding function_binding;

  // 功能：构造默认 core-only 配置，关闭全部外部适配器并建立确定的超时/profile。
  // 输入输出及副作用：name 为 UVM 对象名；初始化标量、队列能力和空 region 列表，不取得外部资源所有权。
  // 失败边界：构造不会验证 route/region；调用 validate() 或 env.configure() 时才报告非法配置。
  function new(string name = "rdma_env_config");
    super.new(name);
    mode = RDMA_ENV_CORE_ONLY;
    hardware_version = 1;
    pcie_enabled = 1'b0;
    pcie_required = 1'b0;
    host_mem_enabled = 1'b0;
    host_mem_required = 1'b0;
    net_enabled = 1'b0;
    net_required = 1'b0;
    operation_timeout = 1us;
    queue_profile = '{default:'0};
    responder_regions.delete();
    function_identity = null;
    function_binding = null;
  endfunction

  // 功能：校验模式、adapter enable/required 关系、超时和每个 responder region 的地址边界。
  // 输入输出及副作用：读取当前配置并返回 rdma_status；不修改配置或外部账本。
  // 失败边界：required 未同时 enabled、timeout/硬件版本为零、region 为空 owner、非法 route、size=0 或 65-bit 末地址溢出时拒绝。
  function rdma_status validate();
    bit [64:0] end_ext;
    if (hardware_version == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "hardware version is zero");
    if (operation_timeout == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "operation timeout is zero");
    if (pcie_required && !pcie_enabled)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "PCIe required without enable");
    if (host_mem_required && !host_mem_enabled)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "host-memory required without enable");
    if (net_required && !net_enabled)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "network required without enable");
    if (!(mode inside {RDMA_ENV_CORE_ONLY, RDMA_ENV_MODEL_ONLY,
                       RDMA_ENV_DUT, RDMA_ENV_HYBRID}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "environment mode is invalid");
    if (mode == RDMA_ENV_CORE_ONLY &&
        (pcie_enabled || host_mem_enabled || net_enabled))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "core-only mode cannot enable adapters");
    foreach (responder_regions[index]) begin
      if (responder_regions[index] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "responder region is null");
      if (!rdma_route_key_valid(responder_regions[index].route))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "responder route is invalid");
      if (responder_regions[index].size == 0 ||
          responder_regions[index].owner.len() == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "responder region size or owner is invalid");
      end_ext = {1'b0, responder_regions[index].base.value} +
                {1'b0, responder_regions[index].size} - 65'd1;
      if (end_ext[64])
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "responder region end overflows 64 bits");
    end
    if (function_identity != null) begin
      if (!function_identity.validate().ok())
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "Function identity snapshot is invalid");
    end
    if (function_binding != null) begin
      if (!function_binding.validate().ok())
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "Function binding snapshot is invalid");
      if (function_identity != null &&
          (function_binding.function_uid != function_identity.function_uid ||
           function_binding.generation != function_identity.generation ||
           function_binding.global_function_id != function_identity.global_function_id))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "Function identity and binding snapshots disagree");
    end
    return rdma_status::success();
  endfunction

  // 功能：深拷贝配置对象，尤其是 responder value region 和 Function identity，形成 detached snapshot。
  // 输入输出及副作用：rhs 为源 uvm_object；覆盖当前对象字段，源配置和其中的 region 句柄不被修改。
  // 失败边界：rhs 类型错误或 region/identity clone 失败时触发 UVM fatal，避免发布半成品配置。
  virtual function void do_copy(uvm_object rhs);
    rdma_env_config source;
    uvm_object clone_obj;
    rdma_responder_region region_copy;
    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_env_config copy type mismatch")
    mode = source.mode;
    hardware_version = source.hardware_version;
    pcie_enabled = source.pcie_enabled;
    pcie_required = source.pcie_required;
    host_mem_enabled = source.host_mem_enabled;
    host_mem_required = source.host_mem_required;
    net_enabled = source.net_enabled;
    net_required = source.net_required;
    operation_timeout = source.operation_timeout;
    queue_profile = source.queue_profile;
    responder_regions.delete();
    foreach (source.responder_regions[index]) begin
      region_copy = rdma_responder_region::type_id::create($sformatf("region_copy_%0d", index));
      if (source.responder_regions[index] == null || region_copy == null)
        `uvm_fatal("RDMA_COPY_TYPE", "responder region clone failed")
      region_copy.domain = source.responder_regions[index].domain;
      region_copy.mode = source.responder_regions[index].mode;
      region_copy.route = source.responder_regions[index].route;
      region_copy.base = source.responder_regions[index].base;
      region_copy.size = source.responder_regions[index].size;
      region_copy.owner = source.responder_regions[index].owner;
      region_copy.lease_id = source.responder_regions[index].lease_id;
      region_copy.active = source.responder_regions[index].active;
      responder_regions.push_back(region_copy);
    end
    function_identity = null;
    if (source.function_identity != null) begin
      clone_obj = source.function_identity.clone();
      if (clone_obj == null || !$cast(function_identity, clone_obj))
        `uvm_fatal("RDMA_COPY_TYPE", "Function identity clone failed")
    end
    function_binding = null;
    if (source.function_binding != null) begin
      clone_obj = source.function_binding.clone();
      if (clone_obj == null || !$cast(function_binding, clone_obj))
        `uvm_fatal("RDMA_COPY_TYPE", "Function binding clone failed")
    end
  endfunction
endclass
