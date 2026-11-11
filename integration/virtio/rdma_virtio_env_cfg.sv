// 目录/层次：integration/virtio；在 virtio_work project_env_cfg 上追加 RDMA 配置。
// 职责：复用父类的 DPU/VIO/PCIe 参数加载，只增加 RDMA service 需求及业务参数。
// 依赖：project_env_pkg、rdma_aip_cfg_pkg；冻结身份仍只由 dpu_common 解析。
// 所有权/生命周期：本对象拥有 rdma_cfg；pool/VIF 和外部硬件按父配置契约借用。
class rdma_virtio_env_cfg extends project_env_cfg;
  `uvm_object_utils(rdma_virtio_env_cfg)

  rdma_env_cfg rdma_cfg;
  // 组合项目的 RDMA 业务总开关；默认关闭，避免 VIO-only 仿真解析和配置 RDMA。
  bit rdma_enabled;
  dpu_function_key_t rdma_functions[$];
  protected bit rdma_params_loaded;

  // 功能：在完整 VIO 项目配置上创建外部模式的 RDMA 配置。
  // 输入/输出及副作用：name 传给父类；不创建模型设备、Host manager 或 PCIe 组件。
  // 失败/边界：构造不加载参数；平台须在 build 前提供 Intel VIF，RDMA 硬件在初始化前绑定。
  function new(string name = "rdma_virtio_env_cfg");
    super.new(name);
    rdma_cfg = rdma_env_cfg::type_id::create("rdma_cfg");
    rdma_cfg.external_configuration = 1;
    rdma_cfg.vseq_type = "rdma_traffic_vseq";
  endfunction

  // 功能：加载父类参数，并在 RDMA 开启时给选中的权威 Function 声明 service，随后加载 RDMA 场景。
  // 输入/输出及副作用：读取 rdma.enabled；显式 Function/grant 选择会打开 RDMA，空选择在已打开时覆盖全部 DPU Function。
  // 失败/边界：重复调用幂等；关闭时不读取 RDMA 参数、不改 DPU service；开启后空目录、重复/不存在 Function 或参数错误 fatal。
  virtual function void load_params();
    bit seen[string];
    bit enabled;
    rdma_status status;
    string vseq;

    if (rdma_params_loaded)
      return;
    super.load_params();
`ifdef AIP_CMDLINE_SV
    enabled = rdma_enabled;
    `aip_int("rdma", bit, enabled, rdma_enabled)
    rdma_enabled = enabled;
`endif
    if (!rdma_enabled && (rdma_functions.size() != 0 || rdma_cfg.grants.size() != 0))
      rdma_enabled = 1;
    if (!rdma_enabled) begin
      rdma_params_loaded = 1;
      return;
    end
    if (rdma_functions.size() == 0 && rdma_cfg.grants.size() != 0) begin
      foreach (rdma_cfg.grants[i])
        if (rdma_cfg.grants[i] != null)
          rdma_functions.push_back(rdma_cfg.grants[i].key);
    end
    if (rdma_functions.size() == 0) begin
      foreach (dpu_cfg.device_cfg.functions[i])
        rdma_functions.push_back(dpu_cfg.device_cfg.functions[i].key);
    end
    if (rdma_functions.size() == 0 || !rdma_cfg.external_configuration)
      `uvm_fatal("RDMA_VIRTIO_CFG", "nonempty Function selection and external RDMA mode required")

    foreach (rdma_functions[i]) begin
      string key;
      bit found;

      key = dpu_function_key_name(rdma_functions[i]);
      if (seen.exists(key))
        `uvm_fatal("RDMA_VIRTIO_CFG", {"duplicate RDMA Function: ", key})
      seen[key] = 1;
      found = 0;
      foreach (dpu_cfg.device_cfg.functions[j]) begin
        bit declared;
        dpu_service_decl service;

        if (!dpu_same_function_key(rdma_functions[i], dpu_cfg.device_cfg.functions[j].key))
          continue;
        found = 1;
        declared = 0;
        foreach (dpu_cfg.device_cfg.functions[j].services[k])
          if (dpu_cfg.device_cfg.functions[j].services[k].service_kind == DPU_SERVICE_RDMA)
            declared = 1;
        if (declared)
          continue;
        service = dpu_service_decl::type_id::create({"rdma_", key});
        service.service_kind = DPU_SERVICE_RDMA;
        service.service_instance_id = 0;
        dpu_cfg.device_cfg.functions[j].services.push_back(service);
      end
      if (!found)
        `uvm_fatal("RDMA_VIRTIO_CFG", {"RDMA Function absent from dpu_common: ", key})
    end
    rdma_cfg.funcs.delete();
    vseq = rdma_cfg.vseq_type;
    status = rdma_aip_cfg_loader::load(rdma_cfg, vseq);
    if (!status.ok())
      `uvm_fatal("RDMA_VIRTIO_CFG", status.convert2string())
    rdma_cfg.vseq_type = vseq;
    rdma_params_loaded = 1;
  endfunction
endclass
