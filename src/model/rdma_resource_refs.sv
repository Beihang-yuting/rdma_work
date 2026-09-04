// 目录：协议与资源模型层 model/rdma_resource_refs.sv。
// 职责：实现 rdma_resource_refs 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_resource_refs.sv 属于模型层，描述语义请求、资源快照、DMA 映射及生命周期数据。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

typedef enum bit [2:0] {
  RDMA_RESOURCE_NEW        = 3'd0,
  RDMA_RESOURCE_ALLOCATED  = 3'd1,
  RDMA_RESOURCE_PROGRAMMED = 3'd2,
  RDMA_RESOURCE_ACTIVE     = 3'd3,
  RDMA_RESOURCE_QUIESCING  = 3'd4,
  RDMA_RESOURCE_RELEASED   = 3'd5,
  RDMA_RESOURCE_ERROR      = 3'd6
} rdma_resource_state_e;

typedef enum bit {
  RDMA_OWNERSHIP_BORROWED,
  RDMA_OWNERSHIP_CONTROL_PLANE
} rdma_resource_ownership_e;

typedef enum bit [1:0] {
  RDMA_HW_PRESENCE_UNKNOWN,
  RDMA_HW_PRESENCE_PRESENT,
  RDMA_HW_PRESENCE_ABSENT
} rdma_hw_presence_e;

class rdma_backing_ref extends uvm_object;
  `uvm_object_utils(rdma_backing_ref)

  rdma_dma_mapping mapping;
  rdma_resource_ownership_e ownership;
  bit release_complete;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_backing_ref");
    super.new(name);
    mapping = null;
    ownership = RDMA_OWNERSHIP_BORROWED;
    release_complete = 1'b0;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  virtual function rdma_status validate();
    if (mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "backing reference mapping is null");
    if (mapping.state != RDMA_MAPPING_ACTIVE && !release_complete)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "live backing reference mapping is not active");
    if (release_complete && ownership == RDMA_OWNERSHIP_BORROWED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "borrowed backing cannot be marked released");
    return rdma_status::success();
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_backing_ref rhs_ref;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_ref, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "backing reference copy mismatch")
    ownership = rhs_ref.ownership;
    release_complete = rhs_ref.release_complete;
    if (rhs_ref.mapping == null) begin
      mapping = null;
    end
    else begin
      cloned_object = rhs_ref.mapping.clone();
      if (cloned_object == null || !$cast(mapping, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "backing mapping clone mismatch")
    end
  endfunction
endclass

class rdma_hmc_ref extends uvm_object;
  `uvm_object_utils(rdma_hmc_ref)

  rdma_function_handle owner;
  rdma_resource_kind_e object_kind;
  rdma_hmc_fvm_addr_t address;
  longint unsigned size;
  int unsigned first_pbl_index;
  rdma_resource_ownership_e ownership;
  bit release_complete;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_hmc_ref");
    super.new(name);
    owner = null;
    object_kind = RDMA_RESOURCE_MR;
    address = '0;
    size = 0;
    first_pbl_index = 0;
    ownership = RDMA_OWNERSHIP_BORROWED;
    release_complete = 1'b0;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  virtual function rdma_status validate();
    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC reference owner is invalid");
    if (object_kind != RDMA_RESOURCE_MR || size == 0 ||
        first_pbl_index == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MR HMC reference metadata is invalid");
    if (release_complete && ownership == RDMA_OWNERSHIP_BORROWED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "borrowed HMC reference cannot be released");
    return rdma_status::success();
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_hmc_ref rhs_ref;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_ref, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "HMC reference copy mismatch")
    if (rhs_ref.owner == null) begin
      owner = null;
    end
    else begin
      cloned_object = rhs_ref.owner.clone();
      if (cloned_object == null || !$cast(owner, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "HMC owner clone mismatch")
    end
    object_kind = rhs_ref.object_kind;
    address = rhs_ref.address;
    size = rhs_ref.size;
    first_pbl_index = rhs_ref.first_pbl_index;
    ownership = rhs_ref.ownership;
    release_complete = rhs_ref.release_complete;
  endfunction
endclass
