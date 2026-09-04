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

  // 功能：构造 rdma_hmc_lease，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：owner=null；object_kind=RDMA_RESOURCE_FUNCTION；address='0；size='0；alignment='0；active=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hmc_lease 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hmc_lease");
    super.new(name);
    owner = null;
    object_kind = RDMA_RESOURCE_FUNCTION;
    address = '0;
    size = '0;
    alignment = '0;
    active = 1'b0;
  endfunction

  // 功能：将 rhs 中 rdma_hmc_lease 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（HMC lease copy type mismatch），不保留部分有效快照。
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

  // 功能：构造 rdma_hmc_allocator，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：aperture_base='0；aperture_last='0；next_address='0；configured=1'b0；aperture_exhausted=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hmc_allocator 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hmc_allocator");
    super.new(name);
    aperture_base = '0;
    aperture_last = '0;
    next_address = '0;
    configured = 1'b0;
    aperture_exhausted = 1'b0;
  endfunction

  // 功能：判断 valid_object_kind 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：kind（输入）；valid_object_kind 读取 kind 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：valid_object_kind 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected function bit valid_object_kind(rdma_resource_kind_e kind);
    return kind inside {RDMA_RESOURCE_PD, RDMA_RESOURCE_MR,
                        RDMA_RESOURCE_CQ, RDMA_RESOURCE_QP,
                        RDMA_RESOURCE_SRQ, RDMA_RESOURCE_CMQ,
                        RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ};
  endfunction

  // 功能：判断 valid_owner 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：owner（输入）；valid_owner 读取 owner 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：valid_owner 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected function bit valid_owner(rdma_function_handle owner);
    return owner != null && owner.kind == RDMA_RESOURCE_FUNCTION;
  endfunction

  // 功能：在 rdma_hmc_allocator 中，address_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：address（输入）；address_key 可能更新本对象明确拥有的状态；函数返回 string，不取得调用方资源所有权。
// 失败/边界：address_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function string address_key(rdma_hmc_fvm_addr_t address);
    return $sformatf("%016h", address.value);
  endfunction

  // 功能：lease_identity_status 校验 lease、owner、object_kind 与当前对象状态的一致性，并显式处理“HMC lease owner is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：lease（输入）、owner（输入）、object_kind（输入）；lease_identity_status 读取 lease、owner、object_kind 并使用字段 rdma_status、function_uid、object_id、kind、generation；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：lease_identity_status 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE、RDMA_SC_STALE_GENERATION；典型拒绝条件为“HMC lease owner is invalid”“HMC object kind is invalid”；失败路径不提交部分状态或转移未声明资源。

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

  // 功能：在 rdma_hmc_allocator 中，configure 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：base（输入）、aperture_size（输入）；configure 先依据 configured || leases.num(；aperture_size == 0；base.value > (64'hffff_ffff_ffff_ffff - (aperture_size - 1'b1 校验 base、aperture_size；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
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

  // 功能：在 rdma_hmc_allocator 中，allocate 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：owner（输入）、object_kind（输入）、size（输入）、alignment（输入）、address（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output
  //   发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
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

  // 功能：在 rdma_hmc_allocator 中，lookup 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：owner（输入）、object_kind（输入）、address（输入）、size（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为 detached
  //   快照，读取不取得外部资源所有权。
  // 失败/边界：lookup 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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

  // 功能：在 rdma_hmc_allocator 中，release 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：owner（输入）、object_kind（输入）、address（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
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

  // 功能：在 rdma_hmc_allocator 中，release_function 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：owner（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release_function 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
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

  // 功能：check_leaks 校验 leak_count、null 与当前对象状态的一致性，并显式处理“HMC leak filter is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：leak_count（输出）、null（输入）；check_leaks 读取 leak_count、owner 并使用字段 leak_count，并写入 leak_count；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
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
