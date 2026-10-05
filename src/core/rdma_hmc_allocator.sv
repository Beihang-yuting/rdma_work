// 目录：核心执行层 core/rdma_hmc_allocator.sv。
// 职责：实现 rdma_hmc_allocator 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

class rdma_hmc_lease extends uvm_object;
  `uvm_object_utils(rdma_hmc_lease)

  rdma_function_handle owner;
  rdma_resource_kind_e object_kind;
  rdma_hmc_fvm_addr_t address;
  longint unsigned size;
  longint unsigned alignment;
  bit active;

  // 功能：构造 HMC lease，字段置为未激活的默认值。
  // 输入/输出及副作用：name 为 UVM 对象名；owner=null、地址/大小/对齐为 0、active=0。
  // 失败/边界：无。
  function new(string name = "rdma_hmc_lease");
    super.new(name);
    owner = null;
    object_kind = RDMA_RESOURCE_FUNCTION;
    address = '0;
    size = '0;
    alignment = '0;
    active = 1'b0;
  endfunction

  // 功能：把 rhs 的 lease 字段复制到当前对象，owner 做值克隆。
  // 输入/输出及副作用：rhs 只读；写入当前对象全部字段。
  // 失败/边界：rhs 类型不是 rdma_hmc_lease 时 uvm_fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_hmc_lease rhs_lease;

    super.do_copy(rhs);
    if (!$cast(rhs_lease, rhs))
      `uvm_fatal("HMC_COPY_TYPE", "HMC lease copy type mismatch")
    owner = rdma_clone_function_handle_value(rhs_lease.owner,
                                               "HMC lease owner");
    object_kind = rhs_lease.object_kind;
    address = rhs_lease.address;
    size = rhs_lease.size;
    alignment = rhs_lease.alignment;
    active = rhs_lease.active;
  endfunction
endclass

// 一个 allocator 实例对应一个单调递增的 HMC aperture epoch。release/release_function
// 只把 lease 置为 inactive，不回收容量也不复用地址，旧 owner/generation/kind 的地址
// 因此不会重新生效；需要新 epoch 时应重新构造并配置 allocator。
class rdma_hmc_allocator extends uvm_object;
  `uvm_object_utils(rdma_hmc_allocator)

  protected rdma_hmc_fvm_addr_t aperture_base;
  protected rdma_hmc_fvm_addr_t aperture_last;
  protected rdma_hmc_fvm_addr_t next_address;
  protected bit configured;
  protected bit aperture_exhausted;
  protected rdma_hmc_lease leases[string];

  // 功能：构造 HMC allocator，未配置状态。
  // 输入/输出及副作用：name 为 UVM 对象名；aperture 与游标清零，configured/exhausted 置 0。
  // 失败/边界：无。
  function new(string name = "rdma_hmc_allocator");
    super.new(name);
    aperture_base = '0;
    aperture_last = '0;
    next_address = '0;
    configured = 1'b0;
    aperture_exhausted = 1'b0;
  endfunction

  // 功能：判断 kind 是否为允许的 HMC 对象类型。
  // 输入/输出及副作用：只读；返回 bit。
  // 失败/边界：不在 PD/MR/CQ/QP/SRQ/CMQ/CEQ/AEQ 内返回 0。
  protected function bit valid_object_kind(rdma_resource_kind_e kind);
    return kind inside {RDMA_RESOURCE_PD, RDMA_RESOURCE_MR,
                        RDMA_RESOURCE_CQ, RDMA_RESOURCE_QP,
                        RDMA_RESOURCE_SRQ, RDMA_RESOURCE_CMQ,
                        RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ};
  endfunction

  // 功能：判断 owner 是否为非空的 FUNCTION handle。
  // 输入/输出及副作用：只读；返回 bit。
  // 失败/边界：owner 为空或 kind 不是 RDMA_RESOURCE_FUNCTION 返回 0。
  protected function bit valid_owner(rdma_function_handle owner);
    return owner != null && owner.kind == RDMA_RESOURCE_FUNCTION;
  endfunction

  // 功能：把 FVM 地址格式化为 lease 表的字符串键。
  // 输入/输出及副作用：address 只读；返回 16 位十六进制字符串。
  // 失败/边界：无。
  protected function string address_key(rdma_hmc_fvm_addr_t address);
    return $sformatf("%016h", address.value);
  endfunction

  // 功能：校验 lease 与调用方 owner/object_kind 的身份是否一致。
  // 输入/输出及副作用：只读；返回 status。
  // 失败/边界：owner/kind 非法、lease 空或类型/Function 不符返回 INVALID_*；generation 不符返回 STALE_GENERATION。
  protected function rdma_status lease_identity_status(
    rdma_hmc_lease lease,
    rdma_function_handle owner,
    rdma_resource_kind_e object_kind
  );
    if (!valid_owner(owner))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC lease owner is invalid");
    if (!valid_object_kind(object_kind))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC object kind is invalid");
    if (lease == null || lease.owner == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "HMC lease registry is inconsistent");
    if (lease.object_kind != object_kind)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC lease object kind does not match");
    if (lease.owner.function_uid != owner.function_uid ||
        lease.owner.object_id != owner.object_id ||
        lease.owner.kind != owner.kind)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC lease belongs to another Function");
    if (lease.owner.generation != owner.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "HMC lease Function generation is stale");
    if (!lease.owner.same_instance(owner))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "complete HMC Function identity does not match");
    return rdma_status::success();
  endfunction

  // 功能：配置 HMC aperture 区间并重置分配游标。
  // 输入/输出及副作用：base/aperture_size 输入；写入 aperture_base/last、next_address 并置 configured。
  // 失败/边界：已配置或已有 lease、size 为 0、区间 64 位溢出时返回错误且不改状态。
  function rdma_status configure(
    rdma_hmc_fvm_addr_t base,
    longint unsigned aperture_size
  );
    if (configured || leases.num() != 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "HMC aperture is already configured");
    if (aperture_size == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC aperture size is zero");
    if (base.value >
        (64'hffff_ffff_ffff_ffff - (aperture_size - 1'b1)))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC aperture end overflows 64 bits");

    aperture_base = base;
    aperture_last.value = base.value + aperture_size - 1'b1;
    next_address = base;
    configured = 1'b1;
    aperture_exhausted = 1'b0;
    return rdma_status::success();
  endfunction

  // 功能：在 aperture 内按对齐单调分配一段地址并登记 lease。
  // 输入/输出及副作用：owner/kind/size/alignment 输入；address 输出；成功时写入 leases 并推进游标。
  // 失败/边界：未配置、参数非法、对齐非 2 的幂、空间耗尽/溢出、地址键重复时返回错误且 address 为 0。
  function rdma_status allocate(
    rdma_function_handle owner,
    rdma_resource_kind_e object_kind,
    longint unsigned size,
    longint unsigned alignment,
    output rdma_hmc_fvm_addr_t address
  );
    longint unsigned alignment_mask;
    longint unsigned aligned_value;
    longint unsigned allocation_last;
    rdma_hmc_lease lease;
    string key;

    address = '0;
    if (!configured)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "HMC aperture is not configured");
    if (!valid_owner(owner))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC allocation owner is invalid");
    if (!valid_object_kind(object_kind))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC allocation object kind is invalid");
    if (size == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC allocation size is zero");
    if (alignment == 0 || (alignment & (alignment - 1'b1)) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC alignment is not a power of two");
    if (aperture_exhausted)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "HMC aperture is exhausted");

    alignment_mask = alignment - 1'b1;
    if (next_address.value >
        (64'hffff_ffff_ffff_ffff - alignment_mask))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "HMC alignment addition overflows 64 bits");
    aligned_value = (next_address.value + alignment_mask) & ~alignment_mask;
    if (aligned_value < aperture_base.value ||
        aligned_value > aperture_last.value)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "aligned HMC address is outside aperture");
    if ((size - 1'b1) > (aperture_last.value - aligned_value))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "HMC allocation exceeds aperture");
    if (aligned_value >
        (64'hffff_ffff_ffff_ffff - (size - 1'b1)))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "HMC allocation end overflows 64 bits");

    allocation_last = aligned_value + size - 1'b1;
    address.value = aligned_value;
    key = address_key(address);
    if (leases.exists(key)) begin
      address = '0;
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "HMC address incarnation already exists");
    end

    lease = rdma_hmc_lease::type_id::create("lease");
    lease.owner = rdma_clone_function_handle_value(owner,
                                                    "HMC allocation owner");
    lease.object_kind = object_kind;
    lease.address = address;
    lease.size = size;
    lease.alignment = alignment;
    lease.active = 1'b1;
    leases[key] = lease;

    if (allocation_last == aperture_last.value ||
        allocation_last == 64'hffff_ffff_ffff_ffff)
      aperture_exhausted = 1'b1;
    else
      next_address.value = allocation_last + 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：按 owner/kind/address 查询活跃 lease 的大小。
  // 输入/输出及副作用：size 输出；只读，不修改 lease。
  // 失败/边界：未配置、地址未知、身份不符、generation 过期或 lease 已释放时返回错误。
  function rdma_status lookup(
    rdma_function_handle owner,
    rdma_resource_kind_e object_kind,
    rdma_hmc_fvm_addr_t address,
    output longint unsigned size
  );
    string key;
    rdma_status status;

    size = '0;
    if (!configured)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "HMC aperture is not configured");
    key = address_key(address);
    if (!leases.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC address is unknown or forged");
    status = lease_identity_status(leases[key], owner, object_kind);
    if (!status.ok())
      return status;
    if (!leases[key].active)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "HMC lease has been released");
    size = leases[key].size;
    return rdma_status::success();
  endfunction

  // 功能：把指定 lease 置为 inactive（不回收容量）。
  // 输入/输出及副作用：owner/kind/address 输入；仅清 active 标志。
  // 失败/边界：未配置、地址未知、身份不符或已释放时返回错误。
  function rdma_status \release (
    rdma_function_handle owner,
    rdma_resource_kind_e object_kind,
    rdma_hmc_fvm_addr_t address
  );
    string key;
    rdma_status status;

    if (!configured)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "HMC aperture is not configured");
    key = address_key(address);
    if (!leases.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC address is unknown or forged");
    status = lease_identity_status(leases[key], owner, object_kind);
    if (!status.ok())
      return status;
    if (!leases[key].active)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "HMC lease is already released");
    leases[key].active = 1'b0;
    return rdma_status::success();
  endfunction

  // 功能：把 owner 对应 Function 的所有 lease 置为 inactive。
  // 输入/输出及副作用：owner 输入；遍历 leases 清 active。
  // 失败/边界：owner 非法返回 INVALID_ARGUMENT。
  function rdma_status release_function(rdma_function_handle owner);
    if (!valid_owner(owner))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC Function teardown owner is invalid");
    foreach (leases[key]) begin
      if (leases[key].owner != null &&
          leases[key].owner.same_instance(owner))
        leases[key].active = 1'b0;
    end
    return rdma_status::success();
  endfunction

  // 功能：统计仍 active 的 lease 数，作为泄漏检查。
  // 输入/输出及副作用：leak_count 输出；owner 非空时只统计该 Function；只读。
  // 失败/边界：owner 非法返回 INVALID_ARGUMENT；存在 active lease 返回 INVALID_STATE。
  function rdma_status check_leaks(
    output int unsigned leak_count,
    input rdma_function_handle owner = null
  );
    leak_count = 0;
    if (owner != null && !valid_owner(owner))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "HMC leak filter is invalid");
    foreach (leases[key]) begin
      if (leases[key].active &&
          (owner == null ||
           (leases[key].owner != null &&
            leases[key].owner.same_instance(owner))))
        leak_count++;
    end
    if (leak_count != 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               $sformatf("%0d HMC leases leaked",
                                         leak_count));
    return rdma_status::success();
  endfunction
endclass
