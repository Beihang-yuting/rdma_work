// 目录：外部适配器实现层 adapters/host_mem/rdma_host_mem_adapter_pkg.sv。
// 职责：实现 rdma_host_mem_adapter_pkg 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_host_mem_adapter_pkg.sv 属于适配器实现层，提供 host-mem 等后端适配实现。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

package rdma_host_mem_adapter_pkg;
  import uvm_pkg::*;
  import host_mem_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_adapter_pkg::*;
  `include "uvm_macros.svh"

  class rdma_host_mem_release_seal extends uvm_object;

    // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    function new(string name = "rdma_host_mem_release_seal");
      super.new(name);
    endfunction
  endclass

  // Handle identity is intentionally opaque.  It is shared by value-like
  // mapping copies, but there is no numeric token or public identity getter.
  // Only the adapter retains the exact seal that can mark release completion.
  class rdma_host_mem_allocation_identity extends uvm_object;
    `uvm_object_utils(rdma_host_mem_allocation_identity)

    local rdma_host_mem_release_seal release_seal;
    local bit release_complete;

    // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    function new(string name = "rdma_host_mem_allocation_identity");
      super.new(name);
      release_seal = null;
      release_complete = 1'b0;
    endfunction

    // 功能：写入并校验运行所需的配置、身份或资源参数，建立后续操作的边界（接口 initialize）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    function rdma_status initialize(rdma_host_mem_release_seal seal);
      if (seal == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "host memory release seal is null");
      if (release_seal != null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "host memory allocation identity is already sealed"
        );
      release_seal = seal;
      return rdma_status::success();
    endfunction

    // 功能：执行接口 mark_release_complete 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 mark_release_complete）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    function rdma_status mark_release_complete(
      rdma_host_mem_release_seal seal
    );
      if (seal == null || release_seal == null || seal != release_seal)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "host memory release completion seal is invalid"
        );
      if (release_complete)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "host memory release is already complete"
        );
      release_complete = 1'b1;
      return rdma_status::success();
    endfunction

    // 功能：执行接口 completion_status 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 completion_status）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    function rdma_status completion_status(output bit complete);
      complete = 1'b0;
      if (release_seal == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "host memory allocation identity is not sealed"
        );
      complete = release_complete;
      return rdma_status::success();
    endfunction
  endclass

  class rdma_host_mem_mapping extends rdma_dma_mapping;
    `uvm_object_utils(rdma_host_mem_mapping)

    local rdma_host_mem_allocation_identity allocation_identity;

    // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    function new(string name = "rdma_host_mem_mapping");
      super.new(name);
      allocation_identity = null;
    endfunction

    // 功能：写入并校验运行所需的配置、身份或资源参数，建立后续操作的边界（接口 initialize_allocation_identity）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    function rdma_status initialize_allocation_identity(
      rdma_host_mem_release_seal release_seal
    );
      rdma_status status;

      if (allocation_identity != null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "host memory allocation identity is already initialized"
        );
      allocation_identity =
        rdma_host_mem_allocation_identity::type_id::create(
          "allocation_identity"
        );
      if (allocation_identity == null)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "host memory allocation identity creation failed"
        );
      status = allocation_identity.initialize(release_seal);
      if (status == null || !status.ok()) begin
        allocation_identity = null;
        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "host memory allocation identity sealing returned null"
          );
        return status;
      end
      return rdma_status::success();
    endfunction

    // 功能：执行接口 mark_release_complete 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 mark_release_complete）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    function rdma_status mark_release_complete(
      rdma_host_mem_release_seal release_seal
    );
      if (allocation_identity == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "host memory allocation identity is not initialized"
        );
      return allocation_identity.mark_release_complete(release_seal);
    endfunction

    // 功能：释放、撤销或回滚当前对象持有的事务/资源，并保持账本与生命周期一致（接口 release_completion_status）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    virtual function rdma_status release_completion_status(
      output bit release_complete
    );
      release_complete = 1'b0;
      if (allocation_identity == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "host memory allocation identity is not initialized"
        );
      return allocation_identity.completion_status(release_complete);
    endfunction

    // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 same_allocation）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    function bit same_allocation(rdma_host_mem_mapping rhs);
      if (rhs == null)
        return 1'b0;
      return allocation_identity != null &&
             rhs.allocation_identity != null &&
             allocation_identity == rhs.allocation_identity;
    endfunction

    // 功能：读取或查询当前对象的权威状态，并以返回值或 output 参数交付快照（接口 snapshot_release_authority）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    virtual function rdma_status snapshot_release_authority(
      output rdma_dma_mapping snapshot
    );
      rdma_host_mem_mapping typed_snapshot;
      rdma_status status;

      snapshot = null;
      status = make_authority_snapshot(typed_snapshot);
      if (status != null && status.ok())
        snapshot = typed_snapshot;
      return status;
    endfunction

    // 功能：释放、撤销或回滚当前对象持有的事务/资源，并保持账本与生命周期一致（接口 release_authority_status）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    virtual function rdma_status release_authority_status(
      rdma_dma_mapping snapshot
    );
      rdma_host_mem_mapping typed_snapshot;

      if (!$cast(typed_snapshot, snapshot) || typed_snapshot == null ||
          !same_allocation(typed_snapshot))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "host memory allocation release authority changed"
        );
      return rdma_status::success();
    endfunction

    // 功能：依据输入快照构造请求、资源或适配对象，并返回独立的结果载体（接口 make_authority_snapshot）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    function rdma_status make_authority_snapshot(
      output rdma_host_mem_mapping snapshot
    );
      rdma_host_mem_mapping candidate;
      rdma_function_handle function_copy;
      rdma_handle owner_copy;
      uvm_object cloned_object;

      snapshot = null;
      if (allocation_identity == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "host memory allocation identity is not initialized"
        );
      if (function_h == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "DMA mapping Function is null");
      candidate = rdma_host_mem_mapping::type_id::create(
        {get_name(), "_authority"}
      );
      if (candidate == null)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "DMA mapping authority creation failed"
        );

      cloned_object = function_h.clone();
      if (cloned_object == null || !$cast(function_copy, cloned_object) ||
          function_copy == function_h)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "DMA mapping Function clone failed");
      if (!function_copy.same_instance(function_h))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "DMA mapping Function clone changed identity"
        );

      owner_copy = null;
      if (owner_h != null) begin
        cloned_object = owner_h.clone();
        if (cloned_object == null || !$cast(owner_copy, cloned_object) ||
            owner_copy == owner_h)
          return rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "DMA mapping owner clone failed");
        if (!owner_copy.same_instance(owner_h))
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "DMA mapping owner clone changed identity"
          );
      end

      candidate.function_h = function_copy;
      candidate.requester_bdf = requester_bdf;
      candidate.pasid_valid = pasid_valid;
      candidate.pasid = pasid;
      candidate.dma_domain_valid = dma_domain_valid;
      candidate.dma_domain_id = dma_domain_id;
      candidate.backing_addr = backing_addr;
      candidate.iova = iova;
      candidate.size = size;
      candidate.direction = direction;
      candidate.permissions = permissions;
      candidate.state = state;
      candidate.owner_h = owner_copy;
      candidate.allocation_identity = allocation_identity;
      snapshot = candidate;
      return rdma_status::success();
    endfunction

    // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    virtual function void do_copy(uvm_object rhs);
      rdma_host_mem_mapping rhs_mapping;
      rdma_host_mem_allocation_identity destination_identity;

      destination_identity = allocation_identity;
      super.do_copy(rhs);
      if (!$cast(rhs_mapping, rhs))
        `uvm_fatal("HOST_MEM_COPY",
                   "host memory DMA mapping copy type mismatch")
      if (destination_identity != null) begin
        // An established destination remains the same allocation even when
        // public value fields are copied from a different mapping.
        allocation_identity = destination_identity;
      end
      else begin
        // Factory clone/copy into a fresh value preserves the opaque identity.
        allocation_identity = rhs_mapping.allocation_identity;
      end
    endfunction
  endclass

  class rdma_host_mem_allocation_record extends uvm_object;
    `uvm_object_utils(rdma_host_mem_allocation_record)

    rdma_host_mem_mapping authority;
    host_mem_pkg::host_mem_api backing_mem;
    bit active;

    // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    function new(string name = "rdma_host_mem_allocation_record");
      super.new(name);
      authority = null;
      backing_mem = null;
      active = 1'b0;
    endfunction
  endclass

  class rdma_host_mem_adapter extends rdma_host_mem_api;
    `uvm_object_utils(rdma_host_mem_adapter)

    // Upstream owns initialization and lifetime of this manager.  The adapter
    // composes it and never changes its configured address regions.
    host_mem_pkg::host_mem_api mem;

    // Zero selects explicit identity mapping.  A non-zero value is the first
    // IOVA cursor; successful offset mappings align and advance that cursor.
    bit [63:0] iova_base;

    local rdma_host_mem_release_seal release_seal;

    protected rdma_host_mem_allocation_record allocations[$];
    protected bit iova_config_locked;
    protected bit [63:0] locked_iova_base;
    protected bit iova_cursor_valid;
    protected bit [64:0] next_iova;

    // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    function new(string name = "rdma_host_mem_adapter");
      super.new(name);
      mem = null;
      iova_base = '0;
      release_seal = new("adapter_release_seal");
      iova_config_locked = 1'b0;
      locked_iova_base = '0;
      iova_cursor_valid = 1'b0;
      next_iova = '0;
    endfunction

    // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 clone_function_handle）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    protected function rdma_function_handle clone_function_handle(
      rdma_function_handle source
    );
      uvm_object cloned_object;
      rdma_function_handle result;

      if (source == null)
        return null;
      cloned_object = source.clone();
      if (cloned_object == null || !$cast(result, cloned_object))
        return null;
      return result;
    endfunction

    // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 clone_owner_handle）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    protected function rdma_handle clone_owner_handle(rdma_handle source);
      uvm_object cloned_object;
      rdma_handle result;

      if (source == null)
        return null;
      cloned_object = source.clone();
      if (cloned_object == null || !$cast(result, cloned_object))
        return null;
      return result;
    endfunction

    // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 same_handle）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    protected function bit same_handle(rdma_handle lhs, rdma_handle rhs);
      if (lhs == null || rhs == null)
        return lhs == null && rhs == null;
      return lhs.same_instance(rhs);
    endfunction

    // 功能：执行接口 mapping_values_match 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 mapping_values_match）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    protected function bit mapping_values_match(
      rdma_dma_mapping candidate,
      rdma_dma_mapping authority
    );
      if (candidate == null || authority == null)
        return 1'b0;
      return same_handle(candidate.function_h, authority.function_h) &&
             candidate.requester_bdf == authority.requester_bdf &&
             candidate.pasid_valid == authority.pasid_valid &&
             candidate.pasid == authority.pasid &&
             candidate.dma_domain_valid == authority.dma_domain_valid &&
             candidate.dma_domain_id == authority.dma_domain_id &&
             candidate.backing_addr == authority.backing_addr &&
             candidate.iova == authority.iova &&
             candidate.size == authority.size &&
             candidate.direction == authority.direction &&
             candidate.permissions == authority.permissions &&
             candidate.state == authority.state &&
             same_handle(candidate.owner_h, authority.owner_h);
    endfunction

    // 功能：读取或查询当前对象的权威状态，并以返回值或 output 参数交付快照（接口 find_allocation）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    protected function int find_allocation(rdma_host_mem_mapping mapping);
      if (mapping == null)
        return -1;
      foreach (allocations[i]) begin
        if (allocations[i] != null && allocations[i].authority != null &&
            allocations[i].authority.same_allocation(mapping))
          return i;
      end
      return -1;
    endfunction

    // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate_mapping）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    protected function rdma_status validate_mapping(
      rdma_dma_mapping mapping,
      output int allocation_index
    );
      rdma_host_mem_mapping concrete_mapping;

      allocation_index = -1;
      if (mapping == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "DMA mapping is null");
      if (mapping.state != RDMA_MAPPING_ACTIVE)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "DMA mapping is not ACTIVE");
      if (!$cast(concrete_mapping, mapping))
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "DMA mapping has no host allocation identity");
      allocation_index = find_allocation(concrete_mapping);
      if (allocation_index < 0)
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "DMA mapping is not owned by this adapter");
      if (!allocations[allocation_index].active ||
          allocations[allocation_index].authority.state !=
            RDMA_MAPPING_ACTIVE)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "host allocation has been released");
      if (!mapping_values_match(
            mapping, allocations[allocation_index].authority
          ))
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "DMA mapping value fields were modified");
      return rdma_status::success();
    endfunction

    // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate_range）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    protected function rdma_status validate_range(
      rdma_host_mem_allocation_record allocation,
      longint unsigned offset,
      longint unsigned length,
      output bit [63:0] backing_address
    );
      bit [64:0] offset_end;
      bit [64:0] address_sum;
      bit [64:0] address_end;

      backing_address = '0;
      if (allocation == null || allocation.authority == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "allocation ledger entry is invalid");
      offset_end = {1'b0, offset} + {1'b0, length};
      if (offset_end[64] ||
          offset_end > {1'b0, allocation.authority.size})
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "access is outside the DMA mapping");
      if (length == 0)
        return rdma_status::success();
      address_sum =
        {1'b0, allocation.authority.backing_addr.value} + {1'b0, offset};
      if (address_sum[64])
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "backing address addition overflowed");
      address_end = address_sum + {1'b0, length};
      if (address_end > {1'b1, 64'b0})
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "backing access end overflowed");
      backing_address = address_sum[63:0];
      return rdma_status::success();
    endfunction

    // 功能：执行接口 iova_overlaps_active 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 iova_overlaps_active）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    protected function bit iova_overlaps_active(
      bit [63:0] first_iova,
      bit [64:0] end_iova
    );
      bit [64:0] existing_first;
      bit [64:0] existing_end;

      foreach (allocations[i]) begin
        if (allocations[i] == null || !allocations[i].active ||
            allocations[i].authority == null)
          continue;
        existing_first =
          {1'b0, allocations[i].authority.iova.value};
        existing_end = existing_first +
                       {1'b0, allocations[i].authority.size};
        if ({1'b0, first_iova} < existing_end &&
            existing_first < end_iova)
          return 1'b1;
      end
      return 1'b0;
    endfunction

    // 功能：执行接口 choose_iova 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 choose_iova）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    protected function rdma_status choose_iova(
      bit [63:0] backing_address,
      int unsigned size,
      int unsigned alignment,
      output bit [63:0] selected_iova,
      output bit [64:0] committed_cursor
    );
      bit [64:0] cursor;
      bit [64:0] alignment_mask;
      bit [64:0] aligned_cursor;
      bit [64:0] range_end;

      selected_iova = '0;
      committed_cursor = next_iova;
      if (iova_base == 0) begin
        range_end = {1'b0, backing_address} + {1'b0, size};
        if (range_end > {1'b1, 64'b0})
          return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "identity IOVA range overflows 64 bits");
        selected_iova = backing_address;
        committed_cursor = next_iova;
      end
      else begin
        cursor = iova_cursor_valid ? next_iova : {1'b0, iova_base};
        if (cursor[64])
          return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "IOVA cursor is exhausted");
        alignment_mask = {1'b0, alignment - 1'b1};
        aligned_cursor = cursor + alignment_mask;
        if (aligned_cursor[64])
          return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "IOVA alignment overflows 64 bits");
        aligned_cursor = aligned_cursor & ~alignment_mask;
        range_end = aligned_cursor + {1'b0, size};
        if (range_end > {1'b1, 64'b0})
          return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "IOVA allocation end overflows 64 bits");
        selected_iova = aligned_cursor[63:0];
        committed_cursor = range_end;
      end
      if (iova_overlaps_active(selected_iova, range_end))
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "IOVA range overlaps an active mapping");
      return rdma_status::success();
    endfunction

    // 功能：原子地预留或获取所需资源/游标，并记录后续提交所需的所有权证据（接口 allocate）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    virtual function rdma_status allocate(
      rdma_dma_request_context request_context,
      int unsigned size,
      int unsigned alignment,
      rdma_dma_direction_e direction,
      output rdma_dma_mapping mapping
    );
      bit [63:0] backing_address;
      bit [63:0] selected_iova;
      bit [64:0] committed_cursor;
      bit [64:0] backing_end;
      rdma_function_handle function_copy;
      rdma_host_mem_mapping allocated_mapping;
      rdma_host_mem_mapping authority;
      rdma_host_mem_allocation_record allocation;
      rdma_status status;

      mapping = null;
      if (request_context == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "DMA request context is null");
      status = request_context.validate();
      if (!status.ok())
        return status;
      if (mem == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "host_mem API is not configured");
      if (iova_config_locked && iova_base != locked_iova_base)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "IOVA configuration cannot change after a successful allocation"
        );
      if (size == 0 || alignment == 0 ||
          (alignment & (alignment - 1'b1)) != 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "size and alignment must be non-zero and alignment must be a power of two");
      if (!(direction inside {RDMA_DMA_DEVICE_READ,
                              RDMA_DMA_DEVICE_WRITE,
                              RDMA_DMA_BIDIRECTIONAL}))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "DMA direction is invalid");

      backing_address = mem.alloc(size, alignment, `__FILE__, `__LINE__);
      if (backing_address == 64'hffff_ffff_ffff_ffff)
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "host_mem allocation failed");
      backing_end = {1'b0, backing_address} + {1'b0, size};
      if ((backing_address & (alignment - 1'b1)) != 0 ||
          backing_end > {1'b1, 64'b0}) begin
        mem.free(backing_address, `__FILE__, `__LINE__);
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "host_mem returned a misaligned or overflowing allocation"
        );
      end

      status = choose_iova(backing_address, size, alignment,
                           selected_iova, committed_cursor);
      if (!status.ok()) begin
        mem.free(backing_address, `__FILE__, `__LINE__);
        return status;
      end

      function_copy = clone_function_handle(request_context.function_h);
      if (function_copy == null) begin
        mem.free(backing_address, `__FILE__, `__LINE__);
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "Function handle clone failed");
      end
      allocated_mapping = rdma_host_mem_mapping::type_id::create(
        $sformatf("host_mapping_%0d", allocations.size())
      );
      if (allocated_mapping == null) begin
        mem.free(backing_address, `__FILE__, `__LINE__);
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "DMA mapping creation failed");
      end
      status = allocated_mapping.initialize_allocation_identity(release_seal);
      if (!status.ok()) begin
        mem.free(backing_address, `__FILE__, `__LINE__);
        return status;
      end
      allocated_mapping.function_h = function_copy;
      allocated_mapping.requester_bdf = request_context.requester_bdf;
      allocated_mapping.pasid_valid = request_context.pasid_valid;
      allocated_mapping.pasid = request_context.pasid;
      allocated_mapping.dma_domain_valid = request_context.dma_domain_valid;
      allocated_mapping.dma_domain_id = request_context.dma_domain_id;
      allocated_mapping.backing_addr.value = backing_address;
      allocated_mapping.iova.value = selected_iova;
      allocated_mapping.size = size;
      allocated_mapping.direction = direction;
      allocated_mapping.permissions.device_read =
        direction inside {RDMA_DMA_DEVICE_READ, RDMA_DMA_BIDIRECTIONAL};
      allocated_mapping.permissions.device_write =
        direction inside {RDMA_DMA_DEVICE_WRITE, RDMA_DMA_BIDIRECTIONAL};
      allocated_mapping.permissions.atomic = 1'b0;
      allocated_mapping.state = RDMA_MAPPING_ACTIVE;
      allocated_mapping.owner_h = clone_owner_handle(
        request_context.owner_h
      );
      if (request_context.owner_h != null &&
          allocated_mapping.owner_h == null) begin
        mem.free(backing_address, `__FILE__, `__LINE__);
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "DMA mapping owner clone failed");
      end

      status = allocated_mapping.make_authority_snapshot(authority);
      if (!status.ok()) begin
        mem.free(backing_address, `__FILE__, `__LINE__);
        return status;
      end
      if (authority == null ||
          !authority.same_allocation(allocated_mapping) ||
          !mapping_values_match(allocated_mapping, authority)) begin
        mem.free(backing_address, `__FILE__, `__LINE__);
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "DMA mapping authority snapshot is inconsistent"
        );
      end
      allocation = rdma_host_mem_allocation_record::type_id::create(
        $sformatf("host_allocation_%0d", allocations.size())
      );
      if (allocation == null) begin
        mem.free(backing_address, `__FILE__, `__LINE__);
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "allocation ledger entry creation failed");
      end
      allocation.authority = authority;
      allocation.backing_mem = mem;
      allocation.active = 1'b1;
      allocations.push_back(allocation);
      if (!iova_config_locked) begin
        locked_iova_base = iova_base;
        iova_config_locked = 1'b1;
      end
      if (iova_base != 0) begin
        next_iova = committed_cursor;
        iova_cursor_valid = 1'b1;
      end
      mapping = allocated_mapping;
      return rdma_status::success();
    endfunction

    // 功能：向目标后端提交数据/事务并更新本对象的进度或账本状态（接口 write）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    virtual function rdma_status write(
      rdma_dma_mapping mapping,
      longint unsigned offset,
      byte data[]
    );
      int allocation_index;
      bit [63:0] backing_address;
      rdma_status status;

      status = validate_mapping(mapping, allocation_index);
      if (!status.ok())
        return status;
      status = validate_range(allocations[allocation_index], offset,
                              data.size(), backing_address);
      if (!status.ok())
        return status;
      if (data.size() == 0)
        return rdma_status::success();
      allocations[allocation_index].backing_mem.write_mem(
        backing_address, data, `__FILE__, `__LINE__
      );
      return rdma_status::success();
    endfunction

    // 功能：读取或查询当前对象的权威状态，并以返回值或 output 参数交付快照（接口 read）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    virtual function rdma_status read(
      rdma_dma_mapping mapping,
      longint unsigned offset,
      int unsigned size,
      output byte data[]
    );
      int allocation_index;
      bit [63:0] backing_address;
      rdma_status status;

      data = new[0];
      status = validate_mapping(mapping, allocation_index);
      if (!status.ok())
        return status;
      status = validate_range(allocations[allocation_index], offset, size,
                              backing_address);
      if (!status.ok())
        return status;
      if (size == 0)
        return rdma_status::success();
      allocations[allocation_index].backing_mem.read_mem(
        backing_address, size, data, `__FILE__, `__LINE__
      );
      if (data.size() != size) begin
        data = new[0];
        return rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                                 "host_mem read returned the wrong size");
      end
      return rdma_status::success();
    endfunction

    // 功能：释放、撤销或回滚当前对象持有的事务/资源，并保持账本与生命周期一致（接口 \release）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    virtual function rdma_status \release (rdma_dma_mapping mapping);
      int allocation_index;
      rdma_host_mem_mapping concrete_mapping;
      rdma_status status;

      status = validate_mapping(mapping, allocation_index);
      if (!status.ok())
        return status;
      if (!$cast(concrete_mapping, mapping) || concrete_mapping == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "validated host memory mapping lost its concrete type"
        );
      // Functions cannot consume time, so sealing completion and freeing the
      // backing are one adapter operation.  The exact seal is never exposed.
      status = concrete_mapping.mark_release_complete(release_seal);
      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "host memory release completion marking returned null"
        );
      if (!status.ok())
        return status;
      // The authoritative address and original manager select the allocation;
      // no caller-writable field participates in the actual free operation.
      allocations[allocation_index].backing_mem.free(
        allocations[allocation_index].authority.backing_addr.value,
        `__FILE__, `__LINE__
      );
      allocations[allocation_index].active = 1'b0;
      allocations[allocation_index].authority.state = RDMA_MAPPING_RELEASED;
      mapping.state = RDMA_MAPPING_RELEASED;
      return rdma_status::success();
    endfunction

    // host_mem leak_check is manager-global.  leak_count is adapter-owner
    // local; callers should isolate or first release unrelated manager users
    // when they require a pristine global host_mem report.
    // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_leaks）。
    // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
    //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
    // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
    function rdma_status check_leaks(output int unsigned leak_count);
      host_mem_pkg::host_mem_api checked_mem[$];
      bit already_checked;

      leak_count = 0;
      foreach (allocations[i]) begin
        if (allocations[i] != null && allocations[i].active)
          leak_count++;
      end
      if (mem == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "host_mem API is not configured");

      mem.leak_check(`__FILE__, `__LINE__);
      checked_mem.push_back(mem);
      foreach (allocations[i]) begin
        if (allocations[i] == null || allocations[i].backing_mem == null)
          continue;
        already_checked = 1'b0;
        foreach (checked_mem[j]) begin
          if (checked_mem[j] == allocations[i].backing_mem) begin
            already_checked = 1'b1;
            break;
          end
        end
        if (!already_checked) begin
          allocations[i].backing_mem.leak_check(`__FILE__, `__LINE__);
          checked_mem.push_back(allocations[i].backing_mem);
        end
      end
      if (leak_count != 0)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          $sformatf("adapter has %0d active DMA mappings", leak_count)
        );
      return rdma_status::success();
    endfunction
  endclass
endpackage
