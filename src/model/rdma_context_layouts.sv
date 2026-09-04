// 目录：协议与资源模型层 model/rdma_context_layouts.sv。
// 职责：实现 rdma_context_layouts 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_context_layouts.sv 属于模型层，描述语义请求、资源快照、DMA 映射及生命周期数据。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

typedef enum bit [1:0] {
  RDMA_CONTEXT_INVALID = 2'd0,
  RDMA_CONTEXT_VALID   = 2'd1,
  RDMA_CONTEXT_ERROR   = 2'd2
} rdma_context_state_e;

typedef enum bit [1:0] {
  RDMA_MR_PBL0 = 2'd0,
  RDMA_MR_PBL1 = 2'd1,
  RDMA_MR_PBL2 = 2'd2
} rdma_mr_pbl_mode_e;

typedef enum bit [1:0] {
  RDMA_MR_PAGE_4K  = 2'd0,
  RDMA_MR_PAGE_64K = 2'd1,
  RDMA_MR_PAGE_2M  = 2'd2,
  RDMA_MR_PAGE_1G  = 2'd3
} rdma_mr_host_page_size_e;

typedef enum bit {
  RDMA_MR_ADDRESS_VA_BASED   = 1'b0,
  RDMA_MR_ADDRESS_ZERO_BASED = 1'b1
} rdma_mr_address_mode_e;

class rdma_ring_position extends uvm_object;
  `uvm_object_utils(rdma_ring_position)

  int unsigned index;
  bit wrap;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_ring_position");
    super.new(name);
    index = '0;
    wrap = 1'b0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_ring_position rhs_position;

    super.do_copy(rhs);
    if (!$cast(rhs_position, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "ring position copy mismatch")
    index = rhs_position.index;
    wrap = rhs_position.wrap;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  virtual function rdma_status validate();
    return rdma_status::success();
  endfunction

  // 功能：将当前对象的类型、状态或关键标识转换为调用方可消费的值，不产生外部副作用。
  // 输入/输出及副作用：输入为当前对象状态；返回字符串、枚举或只读派生值，不修改对象。
  //   对象未配置时返回可识别的 UNKNOWN/UNCONFIGURED 表示。
  // 失败/边界：未配置或字段无效时返回明确的 UNKNOWN 表示，不读取未初始化句柄。
  virtual function string describe();
    return $sformatf("ring(index=%0d wrap=%0b)", index, wrap);
  endfunction
endclass

class rdma_page_table_layout extends uvm_object;
  `uvm_object_utils(rdma_page_table_layout)

  rdma_object_mode_e mode;
  rdma_backing_addr_t sd_base;
  rdma_backing_addr_t current_base;
  bit current_valid;
  rdma_backing_addr_t next_base;
  bit next_valid;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_page_table_layout");
    super.new(name);
    mode = RDMA_OBJECT_DIRECT_4K;
    sd_base = '0;
    current_base = '0;
    current_valid = 1'b0;
    next_base = '0;
    next_valid = 1'b0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_page_table_layout rhs_layout;

    super.do_copy(rhs);
    if (!$cast(rhs_layout, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "page table layout copy mismatch")
    mode = rhs_layout.mode;
    sd_base = rhs_layout.sd_base;
    current_base = rhs_layout.current_base;
    current_valid = rhs_layout.current_valid;
    next_base = rhs_layout.next_base;
    next_valid = rhs_layout.next_valid;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  virtual function rdma_status validate();
    if (!(mode inside {RDMA_OBJECT_DIRECT_4K, RDMA_OBJECT_INDIRECT_4K,
                       RDMA_OBJECT_HUGE_2M,
                       RDMA_OBJECT_L3_INDIRECT_4K}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "page table object mode is invalid");
    if ((sd_base.value & 64'hfff) != 0 ||
        (current_valid && (current_base.value & 64'hfff) != 0) ||
        (next_valid && (next_base.value & 64'hfff) != 0))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "valid page table base is not 4 KiB aligned");
    return rdma_status::success();
  endfunction

  // 功能：将当前对象的类型、状态或关键标识转换为调用方可消费的值，不产生外部副作用。
  // 输入/输出及副作用：输入为当前对象状态；返回字符串、枚举或只读派生值，不修改对象。
  //   对象未配置时返回可识别的 UNKNOWN/UNCONFIGURED 表示。
  // 失败/边界：未配置或字段无效时返回明确的 UNKNOWN 表示，不读取未初始化句柄。
  virtual function string describe();
    return $sformatf("page_table(mode=%s sd=0x%016x current_valid=%0b next_valid=%0b)",
                     mode.name(), sd_base.value, current_valid, next_valid);
  endfunction
endclass

class rdma_address_vector extends uvm_object;
  `uvm_object_utils(rdma_address_vector)

  int unsigned source_address_index;
  int unsigned source_vport;
  int unsigned destination_vport;
  int unsigned destination_port;
  bit [47:0] destination_mac;
  byte unsigned destination_ip[16];
  bit ipv6;
  bit vlan_enable;
  bit cfi;
  bit lag_enable;
  bit tunnel_enable;
  bit forwarding_enable;
  bit [11:0] vlan_id;
  bit [7:0] traffic_class;
  bit [19:0] flow_label;
  bit [7:0] hop_limit;
  bit [15:0] udp_source_port;
  bit [2:0] \priority ;
  bit multicast;
  bit [1:0] forwarding_mode;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_address_vector");
    super.new(name);
    source_address_index = '0;
    source_vport = '0;
    destination_vport = '0;
    destination_port = '0;
    destination_mac = '0;
    foreach (destination_ip[i])
      destination_ip[i] = '0;
    ipv6 = 1'b0;
    vlan_enable = 1'b0;
    cfi = 1'b0;
    lag_enable = 1'b0;
    tunnel_enable = 1'b0;
    forwarding_enable = 1'b0;
    vlan_id = '0;
    traffic_class = '0;
    flow_label = '0;
    hop_limit = '0;
    udp_source_port = '0;
    \priority = '0;
    multicast = 1'b0;
    forwarding_mode = '0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_address_vector rhs_vector;

    super.do_copy(rhs);
    if (!$cast(rhs_vector, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "address vector copy mismatch")
    source_address_index = rhs_vector.source_address_index;
    source_vport = rhs_vector.source_vport;
    destination_vport = rhs_vector.destination_vport;
    destination_port = rhs_vector.destination_port;
    destination_mac = rhs_vector.destination_mac;
    foreach (destination_ip[i])
      destination_ip[i] = rhs_vector.destination_ip[i];
    ipv6 = rhs_vector.ipv6;
    vlan_enable = rhs_vector.vlan_enable;
    cfi = rhs_vector.cfi;
    lag_enable = rhs_vector.lag_enable;
    tunnel_enable = rhs_vector.tunnel_enable;
    forwarding_enable = rhs_vector.forwarding_enable;
    vlan_id = rhs_vector.vlan_id;
    traffic_class = rhs_vector.traffic_class;
    flow_label = rhs_vector.flow_label;
    hop_limit = rhs_vector.hop_limit;
    udp_source_port = rhs_vector.udp_source_port;
    \priority = rhs_vector.\priority ;
    multicast = rhs_vector.multicast;
    forwarding_mode = rhs_vector.forwarding_mode;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  virtual function rdma_status validate();
    return rdma_status::success();
  endfunction

  // 功能：将当前对象的类型、状态或关键标识转换为调用方可消费的值，不产生外部副作用。
  // 输入/输出及副作用：输入为当前对象状态；返回字符串、枚举或只读派生值，不修改对象。
  //   对象未配置时返回可识别的 UNKNOWN/UNCONFIGURED 表示。
  // 失败/边界：未配置或字段无效时返回明确的 UNKNOWN 表示，不读取未初始化句柄。
  virtual function string describe();
    return $sformatf("address_vector(dmac=%012x vlan=%0d ipv6=%0b)",
                     destination_mac, vlan_id, ipv6);
  endfunction
endclass

class rdma_urc_queue_config extends uvm_object;
  `uvm_object_utils(rdma_urc_queue_config)

  rdma_backing_addr_t rsq_backing;
  rdma_backing_addr_t rdsq_backing;
  rdma_backing_addr_t dsq_backing;
  int unsigned rsq_depth;
  int unsigned rdsq_depth;
  int unsigned rdsq_fetch_count;
  int unsigned dsq_fetch_count;
  int unsigned rq_sequence_threshold_entries;
  int unsigned sq_completion_threshold_entries;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_urc_queue_config");
    super.new(name);
    rsq_backing = '0;
    rdsq_backing = '0;
    dsq_backing = '0;
    rsq_depth = '0;
    rdsq_depth = '0;
    rdsq_fetch_count = '0;
    dsq_fetch_count = '0;
    rq_sequence_threshold_entries = '0;
    sq_completion_threshold_entries = '0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_urc_queue_config rhs_queues;

    super.do_copy(rhs);
    if (!$cast(rhs_queues, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "URC queue configuration copy mismatch")
    rsq_backing = rhs_queues.rsq_backing;
    rdsq_backing = rhs_queues.rdsq_backing;
    dsq_backing = rhs_queues.dsq_backing;
    rsq_depth = rhs_queues.rsq_depth;
    rdsq_depth = rhs_queues.rdsq_depth;
    rdsq_fetch_count = rhs_queues.rdsq_fetch_count;
    dsq_fetch_count = rhs_queues.dsq_fetch_count;
    rq_sequence_threshold_entries =
      rhs_queues.rq_sequence_threshold_entries;
    sq_completion_threshold_entries =
      rhs_queues.sq_completion_threshold_entries;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  virtual function rdma_status validate();
    if ((rsq_backing.value & 64'hfff) != 0 ||
        (rdsq_backing.value & 64'hfff) != 0 ||
        (dsq_backing.value & 64'hfff) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC backing is not 4 KiB aligned");
    if (!rdma_is_power_of_two(rsq_depth) ||
        !rdma_is_power_of_two(rdsq_depth))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "URC queue depth is not a nonzero power of two"
      );
    if (rq_sequence_threshold_entries != 0 &&
        (rq_sequence_threshold_entries < 2 ||
         !rdma_is_power_of_two(rq_sequence_threshold_entries)))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "URC RQ sequence threshold is not zero or a power of two >= 2"
      );
    if (sq_completion_threshold_entries != 0 &&
        (sq_completion_threshold_entries < 2 ||
         !rdma_is_power_of_two(sq_completion_threshold_entries)))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "URC SQ completion threshold is not zero or a power of two >= 2"
      );
    return rdma_status::success();
  endfunction

  // 功能：将当前对象的类型、状态或关键标识转换为调用方可消费的值，不产生外部副作用。
  // 输入/输出及副作用：输入为当前对象状态；返回字符串、枚举或只读派生值，不修改对象。
  //   对象未配置时返回可识别的 UNKNOWN/UNCONFIGURED 表示。
  // 失败/边界：未配置或字段无效时返回明确的 UNKNOWN 表示，不读取未初始化句柄。
  virtual function string describe();
    return $sformatf(
      "urc_queues(rsq_backing=0x%016x rdsq_backing=0x%016x dsq_backing=0x%016x rsq_depth=%0d rdsq_depth=%0d rdsq_fetch_count=%0d dsq_fetch_count=%0d rq_sequence_threshold_entries=%0d sq_completion_threshold_entries=%0d)",
      rsq_backing.value, rdsq_backing.value, dsq_backing.value, rsq_depth,
      rdsq_depth, rdsq_fetch_count, dsq_fetch_count,
      rq_sequence_threshold_entries, sq_completion_threshold_entries
    );
  endfunction
endclass

class rdma_mr_page_layout extends uvm_object;
  `uvm_object_utils(rdma_mr_page_layout)

  rdma_mr_pbl_mode_e pbl_mode;
  rdma_mr_host_page_size_e host_page_size;
  rdma_backing_addr_t pba0;
  rdma_backing_addr_t pba1;
  int unsigned first_pbl_index;
  rdma_mr_address_mode_e address_mode;
  bit odp;
  bit invalidate_enable;
  bit payload_vf_enable;
  int unsigned payload_vf_id;
  int unsigned mr_serial;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_mr_page_layout");
    super.new(name);
    pbl_mode = RDMA_MR_PBL0;
    host_page_size = RDMA_MR_PAGE_4K;
    pba0 = '0;
    pba1 = '0;
    first_pbl_index = '0;
    address_mode = RDMA_MR_ADDRESS_VA_BASED;
    odp = 1'b0;
    invalidate_enable = 1'b0;
    payload_vf_enable = 1'b0;
    payload_vf_id = '0;
    mr_serial = '0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_mr_page_layout rhs_layout;

    super.do_copy(rhs);
    if (!$cast(rhs_layout, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "MR page layout copy mismatch")
    pbl_mode = rhs_layout.pbl_mode;
    host_page_size = rhs_layout.host_page_size;
    pba0 = rhs_layout.pba0;
    pba1 = rhs_layout.pba1;
    first_pbl_index = rhs_layout.first_pbl_index;
    address_mode = rhs_layout.address_mode;
    odp = rhs_layout.odp;
    invalidate_enable = rhs_layout.invalidate_enable;
    payload_vf_enable = rhs_layout.payload_vf_enable;
    payload_vf_id = rhs_layout.payload_vf_id;
    mr_serial = rhs_layout.mr_serial;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  virtual function rdma_status validate();
    case (pbl_mode)
      RDMA_MR_PBL0:
        if ((pba0.value & 64'hfff) != 0 || pba1.value != 0 ||
            first_pbl_index != 0)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL0 layout fields are contradictory");
      RDMA_MR_PBL1:
        if ((pba0.value & 64'hfff) != 0 ||
            (pba1.value & 64'hfff) != 0 || first_pbl_index != 0)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL1 layout fields are contradictory");
      RDMA_MR_PBL2:
        if (pba0.value != 0 || pba1.value != 0 || first_pbl_index == 0)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL2 layout fields are contradictory");
      default:
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MR PBL mode is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：将当前对象的类型、状态或关键标识转换为调用方可消费的值，不产生外部副作用。
  // 输入/输出及副作用：输入为当前对象状态；返回字符串、枚举或只读派生值，不修改对象。
  //   对象未配置时返回可识别的 UNKNOWN/UNCONFIGURED 表示。
  // 失败/边界：未配置或字段无效时返回明确的 UNKNOWN 表示，不读取未初始化句柄。
  virtual function string describe();
    return $sformatf("mr_page(mode=%s page=%s first_pbl=%0d)",
                     pbl_mode.name(), host_page_size.name(),
                     first_pbl_index);
  endfunction
endclass
