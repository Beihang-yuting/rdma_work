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

  // 功能：构造 rdma_backing_ref，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：mapping=null；ownership=RDMA_OWNERSHIP_BORROWED；release_complete=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_backing_ref 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_backing_ref");
    super.new(name);
    mapping = null;
    ownership = RDMA_OWNERSHIP_BORROWED;
    release_complete = 1'b0;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“backing reference mapping is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、mapping、mapping.state、release_complete、ownership 并使用字段 rdma_status、mapping、mapping.state、release_complete、ownership；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；具体拒绝条件包括 “backing reference mapping is null”；“live backing reference mapping is not active”；“borrowed backing cannot be marked released”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
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

  // 功能：将 rhs 中 rdma_backing_ref 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（backing reference copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_backing_ref rhs_ref;

    super.do_copy(rhs);
    if (!$cast(rhs_ref, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "backing reference copy mismatch")
    ownership = rhs_ref.ownership;
    release_complete = rhs_ref.release_complete;
    mapping = rdma_deep_copy#(rdma_dma_mapping)::of(
      rhs_ref.mapping, "backing mapping clone mismatch");
  endfunction
endclass

class rdma_hmc_ref extends uvm_object;
  `uvm_object_utils(rdma_hmc_ref)

  rdma_function_handle owner;
  rdma_resource_kind_e object_kind;
  rdma_hmc_fvm_addr_t address;
  longint unsigned size;
  int unsigned first_pbl_index;
  // 驱动的 PBLE allocator 允许 index=0；该模型元数据位记录 index
  // 是否来自 allocator lease，而不是把 0 当作“未设置”哨兵。它不进入
  // CMQ/MRT wire image，只用于 authority/快照完整性校验。
  bit index_valid;
  rdma_resource_ownership_e ownership;
  bit release_complete;

  // 功能：构造 rdma_hmc_ref，调用 super.new 建立 UVM 对象，并把默认值设为
  //   owner=null、object_kind=RDMA_RESOURCE_MR、address='0、size=0、
  //   first_pbl_index=0、index_valid=1'b0、
  //   ownership=RDMA_OWNERSHIP_BORROWED、release_complete=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hmc_ref 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hmc_ref");
    super.new(name);
    owner = null;
    object_kind = RDMA_RESOURCE_MR;
    address = '0;
    size = 0;
    first_pbl_index = 0;
    index_valid = 1'b0;
    ownership = RDMA_OWNERSHIP_BORROWED;
    release_complete = 1'b0;
  endfunction

  // 功能：validate 校验当前字段与 HMC reference 状态的一致性，并显式处理
  //   “HMC reference owner is invalid”等拒绝条件，返回 rdma_status。
  // 输入/输出及副作用：无显式参数；读取 owner、object_kind、size、
  //   first_pbl_index、index_valid、release_complete 和 ownership，返回状态，
  //   不取得调用方资源所有权。
  // 失败/边界：owner/metadata 无效或 allocator index validity 缺失时返回
  //   RDMA_SC_INVALID_ARGUMENT；借用引用已释放时返回 RDMA_SC_INVALID_STATE；
  //   index_valid=1 时 index=0 合法。
  virtual function rdma_status validate();
    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC reference owner is invalid");
    if (object_kind != RDMA_RESOURCE_MR || size == 0 || !index_valid)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MR HMC reference metadata is invalid");
    if (release_complete && ownership == RDMA_OWNERSHIP_BORROWED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "borrowed HMC reference cannot be released");
    return rdma_status::success();
  endfunction

  // 功能：将 rhs 中 rdma_hmc_ref 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（HMC reference copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_hmc_ref rhs_ref;

    super.do_copy(rhs);
    if (!$cast(rhs_ref, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "HMC reference copy mismatch")
    owner = rdma_deep_copy#(rdma_function_handle)::of(
      rhs_ref.owner, "HMC owner clone mismatch");
    object_kind = rhs_ref.object_kind;
    address = rhs_ref.address;
    size = rhs_ref.size;
    first_pbl_index = rhs_ref.first_pbl_index;
    index_valid = rhs_ref.index_valid;
    ownership = rhs_ref.ownership;
    release_complete = rhs_ref.release_complete;
  endfunction
endclass
