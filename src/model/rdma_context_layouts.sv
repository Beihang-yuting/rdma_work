// 目录：协议与资源模型层 model/rdma_context_layouts.sv。
// 职责：定义 ring 位置、页表、地址向量、URC 队列配置与 MR page layout 等上下文布局值对象。
// 依赖：依赖本层公共 types/model 契约。
// 所有权与生命周期：对象只拥有值快照；外部资源为非拥有引用，生命周期由调用方管理。

// 中文说明：本文件属于模型层，描述上下文布局数据；先看公开类型再看实现。

typedef enum bit [1:0] {
  RDMA_CONTEXT_INVALID = 2'd0,
  RDMA_CONTEXT_VALID   = 2'd1,
  RDMA_CONTEXT_ERROR   = 2'd2
} rdma_context_state_e;

// 驱动 mr.h 将 MRT 状态定义为独立的 INVLD/FREE/VLD 三态；它们与 CQC、SRQC
// 等上下文的 INVALID/VALID/ERROR 不是同一套语义，因此不能复用通用枚举。
typedef enum bit [1:0] {
  RDMA_MR_STATE_INVALID = 2'd0,
  RDMA_MR_STATE_FREE    = 2'd1,
  RDMA_MR_STATE_VALID   = 2'd2
} rdma_mr_state_e;

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

  // 功能：构造对象并设置默认字段值。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无；字段含义以 validate() 为准。
  function new(string name = "rdma_ring_position");
    super.new(name);
    index = '0;
    wrap = 1'b0;
  endfunction

  // 功能：把 rhs 的值字段复制到当前对象。
  // 输入/输出及副作用：rhs 为源对象，不被修改；覆盖当前对象字段。
  // 失败/边界：rhs 类型不匹配时触发 UVM fatal（ring position copy mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_ring_position rhs_position;

    super.do_copy(rhs);
    if (!$cast(rhs_position, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "ring position copy mismatch")
    index = rhs_position.index;
    wrap = rhs_position.wrap;
  endfunction

  // 功能：校验对象字段。
  // 输入/输出及副作用：只读，返回 status。
  // 失败/边界：无约束，恒返回 success。
  virtual function rdma_status validate();
    return rdma_status::success();
  endfunction

  // 功能：生成ring 位置的稳定文本，供日志使用。
  // 输入/输出及副作用：返回 string，只读字段。
  // 失败/边界：无。
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

  // 功能：构造对象并设置默认字段值。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无；字段含义以 validate() 为准。
  function new(string name = "rdma_page_table_layout");
    super.new(name);
    mode = RDMA_OBJECT_DIRECT_4K;
    sd_base = '0;
    current_base = '0;
    current_valid = 1'b0;
    next_base = '0;
    next_valid = 1'b0;
  endfunction

  // 功能：把 rhs 的值字段复制到当前对象。
  // 输入/输出及副作用：rhs 为源对象，不被修改；覆盖当前对象字段。
  // 失败/边界：rhs 类型不匹配时触发 UVM fatal（page table layout copy mismatch）。
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

  // 功能：校验页表 object mode 与基址对齐。
  // 输入/输出及副作用：只读 mode、sd_base，以及 valid 时的 current/next base；返回 status。
  // 失败/边界：mode 非法或有效基址未 4 KiB 对齐时返回 INVALID_ARGUMENT。
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

  // 功能：生成页表布局的稳定文本，供日志使用。
  // 输入/输出及副作用：返回 string，只读字段。
  // 失败/边界：无。
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

  // 功能：构造对象并设置默认字段值。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无；字段含义以 validate() 为准。
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

  // 功能：把 rhs 的值字段复制到当前对象。
  // 输入/输出及副作用：rhs 为源对象，不被修改；覆盖当前对象字段。
  // 失败/边界：rhs 类型不匹配时触发 UVM fatal（address vector copy mismatch）。
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

  // 功能：校验对象字段。
  // 输入/输出及副作用：只读，返回 status。
  // 失败/边界：无约束，恒返回 success。
  virtual function rdma_status validate();
    return rdma_status::success();
  endfunction

  // 功能：生成地址向量的稳定文本，供日志使用。
  // 输入/输出及副作用：返回 string，只读字段。
  // 失败/边界：无。
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

  // 功能：构造对象并设置默认字段值。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无；字段含义以 validate() 为准。
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

  // 功能：把 rhs 的值字段复制到当前对象。
  // 输入/输出及副作用：rhs 为源对象，不被修改；覆盖当前对象字段。
  // 失败/边界：rhs 类型不匹配时触发 UVM fatal（URC queue configuration copy mismatch）。
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

  // 功能：校验 URC 队列配置。
  // 输入/输出及副作用：只读 backing、depth 与两个 threshold；返回 status。
  // 失败/边界：backing 未 4 KiB 对齐、depth 非 2 的幂，或 RQ sequence/SQ completion threshold
  //   非 0 且小于 2 或非 2 的幂时返回 INVALID_ARGUMENT。
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

  // 功能：生成URC 队列配置的稳定文本，供日志使用。
  // 输入/输出及副作用：返回 string，只读字段。
  // 失败/边界：无。
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
  // 驱动 PBLE allocator 允许 index=0；该模型专用位区分 allocator lease
  // 产生的零索引与遗漏或伪造的索引。它只属于 authority 元数据，不编码进
  // MRT context image。
  bit first_pbl_index_valid;
  rdma_mr_address_mode_e address_mode;
  bit odp;
  bit invalidate_enable;
  bit payload_vf_enable;
  int unsigned payload_vf_id;
  int unsigned mr_serial;

  // 功能：构造 MR page layout 并设置默认字段值。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_mr_page_layout");
    super.new(name);
    pbl_mode = RDMA_MR_PBL0;
    host_page_size = RDMA_MR_PAGE_4K;
    pba0 = '0;
    pba1 = '0;
    first_pbl_index = '0;
    first_pbl_index_valid = 1'b0;
    address_mode = RDMA_MR_ADDRESS_VA_BASED;
    odp = 1'b0;
    invalidate_enable = 1'b0;
    payload_vf_enable = 1'b0;
    payload_vf_id = '0;
    mr_serial = '0;
  endfunction

  // 功能：把 rhs 的值字段复制到当前对象。
  // 输入/输出及副作用：rhs 为源对象，不被修改；覆盖当前对象字段。
  // 失败/边界：rhs 类型不匹配时触发 UVM fatal（MR page layout copy mismatch）。
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
    first_pbl_index_valid = rhs_layout.first_pbl_index_valid;
    address_mode = rhs_layout.address_mode;
    odp = rhs_layout.odp;
    invalidate_enable = rhs_layout.invalidate_enable;
    payload_vf_enable = rhs_layout.payload_vf_enable;
    payload_vf_id = rhs_layout.payload_vf_id;
    mr_serial = rhs_layout.mr_serial;
  endfunction

  // 功能：校验 PBL mode 与 pba0/pba1/first_pbl_index 及 validity 的一致性。
  // 输入/输出及副作用：只读相关字段，返回 status。
  // 失败/边界：PBL0/PBL1 字段矛盾或 PBL2 validity 缺失返回 INVALID_ARGUMENT；PBL2 的 index=0
  //   仅在 validity=1 时通过。
  virtual function rdma_status validate();
    case (pbl_mode)
      RDMA_MR_PBL0:
        if ((pba0.value & 64'hfff) != 0 || pba1.value != 0 ||
            first_pbl_index != 0 || first_pbl_index_valid)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL0 layout fields are contradictory");
      RDMA_MR_PBL1:
        if ((pba0.value & 64'hfff) != 0 ||
            (pba1.value & 64'hfff) != 0 || first_pbl_index != 0 ||
            first_pbl_index_valid)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL1 layout fields are contradictory");
      RDMA_MR_PBL2:
        if (pba0.value != 0 || pba1.value != 0 || !first_pbl_index_valid)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL2 layout fields are contradictory");
      default:
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MR PBL mode is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：只校验 MRT image 能表达的 PBL mode/PBA/index 形状，供无 HMC lease 的编解码模型使用。
  // 输入/输出及副作用：只读相关字段，返回 status。
  // 失败/边界：PBL0/PBL1 的 PBA、index 与 mode 矛盾返回 INVALID_ARGUMENT；PBL2 只要求 index 在
  //   wire 域且 PBA 为空，allocator validity 由 rdma_mr_backing_desc/rdma_pbl 校验。
  virtual function rdma_status validate_wire_shape();
    case (pbl_mode)
      RDMA_MR_PBL0:
        if ((pba0.value & 64'hfff) != 0 || pba1.value != 0 ||
            first_pbl_index != 0 || first_pbl_index_valid)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL0 wire fields are contradictory");
      RDMA_MR_PBL1:
        if ((pba0.value & 64'hfff) != 0 ||
            (pba1.value & 64'hfff) != 0 || first_pbl_index != 0 ||
            first_pbl_index_valid)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL1 wire fields are contradictory");
      RDMA_MR_PBL2:
        if (pba0.value != 0 || pba1.value != 0)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL2 wire fields are contradictory");
      default:
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "MR PBL mode is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：生成MR page layout的稳定文本，供日志使用。
  // 输入/输出及副作用：返回 string，只读字段。
  // 失败/边界：无。
  virtual function string describe();
    return $sformatf("mr_page(mode=%s page=%s first_pbl=%0d)",
                     pbl_mode.name(), host_page_size.name(),
                     first_pbl_index);
  endfunction
endclass
