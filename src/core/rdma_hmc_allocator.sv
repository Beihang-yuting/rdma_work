// 目录：核心执行层 core/rdma_hmc_allocator.sv。
// 职责：实现 rdma_hmc_allocator 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_hmc_allocator.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_hmc_lease extends uvm_object;
  `uvm_object_utils(rdma_hmc_lease)

  rdma_function_handle owner;
  rdma_resource_kind_e object_kind;
  rdma_hmc_fvm_addr_t address;
  longint unsigned size;
  longint unsigned alignment;
  bit active;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_hmc_lease");
    super.new(name);
    owner = null;
    object_kind = RDMA_RESOURCE_FUNCTION;
    address = '0;
    size = '0;
    alignment = '0;
    active = 1'b0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
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

// One allocator instance represents one monotonic HMC aperture epoch.
// Individual release and release_function() only make leases inactive; they
// intentionally do not reclaim capacity or reuse addresses, so an old
// owner/generation/kind address can never become live again.  Start a new
// aperture epoch by constructing and configuring a new allocator object.
class rdma_hmc_allocator extends uvm_object;
  `uvm_object_utils(rdma_hmc_allocator)

  protected rdma_hmc_fvm_addr_t aperture_base;
  protected rdma_hmc_fvm_addr_t aperture_last;
  protected rdma_hmc_fvm_addr_t next_address;
  protected bit configured;
  protected bit aperture_exhausted;
  protected rdma_hmc_lease leases[string];

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_hmc_allocator");
    super.new(name);
    aperture_base = '0;
    aperture_last = '0;
    next_address = '0;
    configured = 1'b0;
    aperture_exhausted = 1'b0;
  endfunction

  // 功能：判断 valid_object_kind 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：参数 RDMA_RESOURCE_PD, RDMA_RESOURCE_MR 用于执行 valid_object_kind；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：valid_object_kind 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected function bit valid_object_kind(rdma_resource_kind_e kind);
    return kind inside {RDMA_RESOURCE_PD, RDMA_RESOURCE_MR,
                        RDMA_RESOURCE_CQ, RDMA_RESOURCE_QP,
                        RDMA_RESOURCE_SRQ, RDMA_RESOURCE_CMQ,
                        RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ};
  endfunction

  // 功能：判断 valid_owner 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：参数 owner 用于执行 valid_owner；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：valid_owner 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected function bit valid_owner(rdma_function_handle owner);
    return owner != null && owner.kind == RDMA_RESOURCE_FUNCTION;
  endfunction

  // 功能：处理 address_key：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 value 用于执行 address_key；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：address_key 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function string address_key(rdma_hmc_fvm_addr_t address);
    return $sformatf("%016h", address.value);
  endfunction

  // 功能：处理 lease_identity_status：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 lease, owner, object_kind 用于执行 lease_identity_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：lease_identity_status 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
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

  // 功能：校验依赖并建立该对象的运行边界，成功后保存必要的非拥有引用；拒绝不完整或重复配置。
  // 输入/输出及副作用：接收 manager、binding、router 或 profile 等依赖；成功后保存非拥有引用并更新配置状态。
  //   任一依赖为空、重复配置或代际不匹配时保持原状态并返回错误。
  // 失败/边界：配置失败不得写入半成品引用；已激活对象不得被无条件降级或重复占用资源。
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

  // 功能：检查可用容量并预留所需资源，返回带所有权证据的分配结果；容量不足时不留下部分分配。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
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

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
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

  // 功能：按资源所有权和幂等规则释放或清理记录；重复释放不会再次扣减 credit，也不触碰已隔离资源。
  // 输入/输出及副作用：输入为待解除或释放的 handle/key；成功后隔离或删除本对象记录，外部拥有者仍负责真正销毁。
  //   空值、未知记录或重复调用按接口约定返回错误或幂等成功。
  // 失败/边界：不得释放非本对象所有资源；重复解除按幂等约定处理，旧 handle 不得重新激活。
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

  // 功能：按资源所有权和幂等规则释放或清理记录；重复释放不会再次扣减 credit，也不触碰已隔离资源。
  // 输入/输出及副作用：输入为待解除或释放的 handle/key；成功后隔离或删除本对象记录，外部拥有者仍负责真正销毁。
  //   空值、未知记录或重复调用按接口约定返回错误或幂等成功。
  // 失败/边界：不得释放非本对象所有资源；重复解除按幂等约定处理，旧 handle 不得重新激活。
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

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
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
