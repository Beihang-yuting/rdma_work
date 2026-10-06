// 目录：协议与资源模型层 model/rdma_resource_refs.sv。
// 职责：实现 rdma_resource_refs 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。
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

class rdma_backing_ref extends uvm_object;
  `rdma_object_utils(rdma_backing_ref)

  rdma_dma_mapping mapping;
  rdma_resource_ownership_e ownership;
  bit release_complete;

  // 功能：构造 backing reference，默认无 mapping、借用所有权、未释放。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_backing_ref");
    super.new(name);
    mapping = null;
    ownership = RDMA_OWNERSHIP_BORROWED;
    release_complete = 1'b0;
  endfunction

  // 功能：校验 backing reference 的 mapping 与释放状态。
  // 输入/输出及副作用：只读对象字段，返回 rdma_status。
  // 失败/边界：mapping 为 null 为 INVALID_ARGUMENT；未释放时 mapping 非 ACTIVE、
  //   或借用 backing 被标记 released 为 INVALID_STATE。
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

  // 功能：把 rhs 的字段复制到当前对象，mapping 深拷贝。
  // 输入/输出及副作用：覆盖当前对象字段，不修改 rhs。
  // 失败/边界：rhs 类型不匹配时 uvm_fatal（backing reference copy mismatch）。
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
  `rdma_object_utils(rdma_hmc_ref)

  rdma_function_handle owner;
  rdma_resource_kind_e object_kind;
  rdma_hmc_fvm_addr_t address;
  longint unsigned size;
  int unsigned first_pbl_index;
  // 驱动的 PBLE allocator 允许 index=0，故用 index_valid 记录 index 是否来自 allocator
  // lease，而非把 0 当“未设置”；不进入 CMQ/MRT wire image，仅用于快照完整性校验。
  bit index_valid;
  rdma_resource_ownership_e ownership;
  bit release_complete;

  // 功能：构造 HMC reference，默认 MR、借用所有权、index_valid=0，其余清零。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
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

  // 功能：校验 HMC reference 的 owner、MR 元数据与释放状态。
  // 输入/输出及副作用：只读对象字段，返回 rdma_status。
  // 失败/边界：owner 非 Function、非 MR、size==0 或 index_valid==0 为 INVALID_ARGUMENT；
  //   借用引用已 release_complete 为 INVALID_STATE；index_valid=1 时 index=0 合法。
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

  // 功能：把 rhs 的字段复制到当前对象，owner 深拷贝。
  // 输入/输出及副作用：覆盖当前对象字段，不修改 rhs。
  // 失败/边界：rhs 类型不匹配时 uvm_fatal（HMC reference copy mismatch）。
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
