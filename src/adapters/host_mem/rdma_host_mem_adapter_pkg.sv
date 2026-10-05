// 目录：外部适配器实现层 adapters/host_mem/rdma_host_mem_adapter_pkg.sv。
// 职责：基于 host_mem 后端实现 rdma_host_mem_api：分配/释放 backing、IOVA 映射与 UMEM 页管理。
// 依赖：host_mem_pkg、rdma_types_pkg、rdma_model_pkg、rdma_adapter_pkg。
// 所有权与生命周期：adapter 组合上游提供的 host_mem manager（非拥有）；allocation/UMEM 账本由 adapter 独占。

package rdma_host_mem_adapter_pkg;
  import uvm_pkg::*;
  import host_mem_pkg::*;
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_adapter_pkg::*;
  `include "uvm_macros.svh"

  class rdma_host_mem_release_seal extends uvm_object;

    // 功能：构造 release seal（仅用作不可伪造的身份令牌）。
    // 输入/输出及副作用：name 为对象名。
    // 失败/边界：无。
    function new(string name = "rdma_host_mem_release_seal");
      super.new(name);
    endfunction
  endclass

  // Handle identity is intentionally opaque.  It is shared by value-like
  // mapping copies, but there is no numeric token or public identity getter.
  // Only the adapter retains the exact seal that can mark release completion.
  class rdma_host_mem_allocation_identity extends uvm_object;
    `rdma_object_utils(rdma_host_mem_allocation_identity)

    local rdma_host_mem_release_seal release_seal;
    local bit release_complete;

    // 功能：构造未封印的 allocation identity。
    // 输入/输出及副作用：name 为对象名；seal 与 release_complete 清零。
    // 失败/边界：无。
    function new(string name = "rdma_host_mem_allocation_identity");
      super.new(name);
      release_seal = null;
      release_complete = 1'b0;
    endfunction

    // 功能：用 seal 封印该 identity，之后只有同一 seal 能标记释放完成。
    // 输入/输出及副作用：成功时锁存 release_seal。
    // 失败/边界：seal 为 null 返回 INVALID_ARGUMENT；已封印返回 INVALID_STATE。
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

    // 功能：用持有的 seal 标记 backing 释放完成。
    // 输入/输出及副作用：成功时置 release_complete。
    // 失败/边界：seal 为 null/未封印/与封印不符返回 INVALID_ARGUMENT；重复标记返回 INVALID_STATE。
    virtual function rdma_status mark_release_complete(
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

    // 功能：查询释放是否已完成。
    // 输入/输出及副作用：complete 先清零，成功时输出 release_complete。
    // 失败/边界：未封印返回 INVALID_STATE。
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
    `rdma_object_utils(rdma_host_mem_mapping)

    local rdma_host_mem_allocation_identity allocation_identity;

    // 功能：构造未绑定 allocation identity 的 mapping。
    // 输入/输出及副作用：name 为对象名。
    // 失败/边界：无。
    function new(string name = "rdma_host_mem_mapping");
      super.new(name);
      allocation_identity = null;
    endfunction

    // 功能：创建并封印该 mapping 的 allocation identity。
    // 输入/输出及副作用：成功时写入 allocation_identity。
    // 失败/边界：已初始化返回 INVALID_STATE；创建失败返回 RESOURCE_EXHAUSTED；封印失败（含 null status）回退为未初始化。
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
          return rdma_status::make_direct(
            RDMA_SC_INVALID_STATE,
            "host memory allocation identity sealing returned null"
          );
        return status;
      end
      return rdma_status::success();
    endfunction

    // 功能：转发 seal 以标记该 mapping 的 backing 释放完成。
    // 输入/输出及副作用：委托 allocation_identity.mark_release_complete。
    // 失败/边界：identity 未初始化返回 INVALID_STATE；其余由 identity 返回。
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

    // 功能：查询该 mapping 的 backing 是否已释放完成。
    // 输入/输出及副作用：release_complete 先清零，再由 identity 填充。
    // 失败/边界：identity 未初始化返回 INVALID_STATE。
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

    // 功能：判断两个 mapping 是否共享同一 allocation identity 对象。
    // 输入/输出及副作用：只读；返回 bit。
    // 失败/边界：rhs 为空或任一 identity 未建立返回 0。
    function bit same_allocation(rdma_host_mem_mapping rhs);
      if (rhs == null)
        return 1'b0;
      return allocation_identity != null &&
             rhs.allocation_identity != null &&
             allocation_identity == rhs.allocation_identity;
    endfunction

    // 功能：生成 release authority 快照（共享 identity 的 detached mapping）。
    // 输入/输出及副作用：snapshot 先置 null，成功时输出 typed 快照。
    // 失败/边界：make_authority_snapshot 返回 null status 时转为 INVALID_STATE。
    virtual function rdma_status snapshot_release_authority(
      output rdma_dma_mapping snapshot
    );
      rdma_host_mem_mapping typed_snapshot;
      rdma_status status;

      snapshot = null;
      status = make_authority_snapshot(typed_snapshot);
      if (status == null)
        return rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "host memory authority snapshot returned null status"
        );
      if (status.ok())
        snapshot = typed_snapshot;
      return status;
    endfunction

    // 功能：确认快照仍与当前 mapping 同属一个 allocation。
    // 输入/输出及副作用：只读。
    // 失败/边界：类型不符、为 null 或不是同一 allocation 返回 INVALID_ARGUMENT。
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

    // 功能：克隆 Function/owner handle 并复制公开字段，得到共享 identity 的 authority mapping。
    // 输入/输出及副作用：snapshot 先置 null；不修改当前 mapping。
    // 失败/边界：identity 未初始化/Function 为空/clone 失败或 clone 改变身份返回 INVALID_STATE；创建失败返回
    //   RESOURCE_EXHAUSTED。
    function rdma_status make_authority_snapshot(
      output rdma_host_mem_mapping snapshot
    );
      rdma_host_mem_mapping candidate;
      rdma_function_handle function_copy;
      rdma_handle owner_copy;

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

      if (!rdma_deep_copy#(rdma_function_handle)::try_of(function_h, function_copy))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "DMA mapping Function clone failed");
      if (!function_copy.same_instance(function_h))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "DMA mapping Function clone changed identity"
        );

      owner_copy = null;
      if (owner_h != null) begin
        if (!rdma_deep_copy#(rdma_handle)::try_of(owner_h, owner_copy))
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
      candidate.route = route;
      candidate.route_valid = route_valid;
      candidate.reset_epoch = reset_epoch;
      candidate.epoch_valid = epoch_valid;
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

    // 功能：复制 rhs 的 mapping 字段并处理 allocation identity。
    // 输入/输出及副作用：目标已有 identity 时保留，否则取 rhs 的 identity（不透明共享）。
    // 失败/边界：类型不匹配触发 uvm_fatal。
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
    `rdma_object_utils(rdma_host_mem_allocation_record)

    rdma_host_mem_mapping authority;
    host_mem_pkg::host_mem_api backing_mem;
    bit active;

    // 功能：构造空 allocation 记录。
    // 输入/输出及副作用：name 为对象名；authority/backing_mem 置 null，active=0。
    // 失败/边界：无。
    function new(string name = "rdma_host_mem_allocation_record");
      super.new(name);
      authority = null;
      backing_mem = null;
      active = 1'b0;
    endfunction
  endclass

  // 功能：记录 host_mem 后端为 UMEM 每页分配的地址，供 unpin 时逆序回收。
  // 输入/输出及副作用：由 adapter 创建并更新；只保存 manager 非拥有引用和地址快照。
  // 失败/边界：active=0 表示已回收；重复回收不得再次调用 host_mem.free。
  class rdma_host_mem_umem_record extends uvm_object;
    `rdma_object_utils(rdma_host_mem_umem_record)

    rdma_umem umem;
    host_mem_pkg::host_mem_api backing_mem;
    bit [63:0] backing_addresses[$];
    bit active;

    // 功能：构造空 UMEM allocation 记录。
    // 输入/输出及副作用：name 为对象名；只初始化本地账本，不访问 host_mem。
    // 失败/边界：未填充 umem/backing_mem 的记录不能提交到 adapter 账本。
    function new(string name = "rdma_host_mem_umem_record");
      super.new(name);
      umem = null;
      backing_mem = null;
      backing_addresses.delete();
      active = 1'b0;
    endfunction
  endclass

  class rdma_host_mem_adapter extends rdma_host_mem_api;
    `rdma_object_utils(rdma_host_mem_adapter)

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
    protected rdma_host_mem_umem_record umem_allocations[$];

    // 功能：构造 adapter（无 manager、IOVA 为恒等模式、账本为空）。
    // 输入/输出及副作用：name 为对象名；创建 release_seal。
    // 失败/边界：使用前须由上游设置 mem。
    function new(string name = "rdma_host_mem_adapter");
      super.new(name);
      mem = null;
      iova_base = '0;
      release_seal = new("adapter_release_seal");
      iova_config_locked = 1'b0;
      locked_iova_base = '0;
      iova_cursor_valid = 1'b0;
      next_iova = '0;
      umem_allocations.delete();
    endfunction

    // 功能：把内部/可覆盖子对象返回的 status 规范化为非空对象。
    // 输入/输出及副作用：非空 candidate 原样返回；null 转为 INVALID_STATE（不经 factory）；不改账本。
    // 失败/边界：null 表示下游违反契约，调用方须停止读取相关 output。
    protected function automatic rdma_status normalize_adapter_status(
      rdma_status candidate,
      string operation
    );
      return rdma_adapter_status_policy::normalize(
        candidate, "Host-memory adapter", operation
      );
    endfunction

    // 功能：克隆 Function handle。
    // 输入/输出及副作用：source 只读；返回新 handle。
    // 失败/边界：source 为空或 clone 失败返回 null。
    protected function rdma_function_handle clone_function_handle(
      rdma_function_handle source
    );
      rdma_function_handle result;

      if (source == null)
        return null;
      if (!rdma_deep_copy#(rdma_function_handle)::try_of(source, result))
        return null;
      return result;
    endfunction

    // 功能：克隆 owner handle。
    // 输入/输出及副作用：source 只读；返回新 handle。
    // 失败/边界：source 为空或 clone 失败返回 null。
    protected function rdma_handle clone_owner_handle(rdma_handle source);
      rdma_handle result;

      if (source == null)
        return null;
      if (!rdma_deep_copy#(rdma_handle)::try_of(source, result))
        return null;
      return result;
    endfunction

    // 功能：按 same_instance 比较两个 handle。
    // 输入/输出及副作用：只读；返回 bit。
    // 失败/边界：两者均为 null 视为相同，仅一方为 null 视为不同。
    protected function bit same_handle(rdma_handle lhs, rdma_handle rhs);
      if (lhs == null || rhs == null)
        return lhs == null && rhs == null;
      return lhs.same_instance(rhs);
    endfunction

    // 功能：比较 mapping 的 Function、BDF/PASID/domain、route/epoch、地址、方向、权限、状态与 owner。
    // 输入/输出及副作用：只读；返回 bit。
    // 失败/边界：任一为 null 或任一字段不等返回 0。
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
             candidate.route_valid == authority.route_valid &&
             candidate.route.host_topology_key ==
               authority.route.host_topology_key &&
             candidate.route.root_id == authority.route.root_id &&
             candidate.route.segment == authority.route.segment &&
             rdma_bdf_same(candidate.route.bdf, authority.route.bdf) &&
             candidate.epoch_valid == authority.epoch_valid &&
             candidate.reset_epoch == authority.reset_epoch &&
             candidate.backing_addr == authority.backing_addr &&
             candidate.iova == authority.iova &&
             candidate.size == authority.size &&
             candidate.direction == authority.direction &&
             candidate.permissions == authority.permissions &&
             candidate.state == authority.state &&
             same_handle(candidate.owner_h, authority.owner_h);
    endfunction

    // 功能：在账本中按 allocation identity 查找 mapping。
    // 输入/输出及副作用：只读；返回下标。
    // 失败/边界：mapping 为空或未找到返回 -1。
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

    // 功能：校验 mapping 为本 adapter 持有的、字段未被篡改的 ACTIVE 分配，并输出账本下标。
    // 输入/输出及副作用：allocation_index 先置 -1。
    // 失败/边界：为空 INVALID_ARGUMENT；非 ACTIVE 或已释放 INVALID_STATE；无 identity/非本 adapter/字段被改
    //   DMA_TRANSLATION。
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

    // 功能：校验 offset/length 落在 mapping 内，并算出对应 backing 地址。
    // 输入/输出及副作用：backing_address 先清零；只读账本。
    // 失败/边界：账本项无效返回 INVALID_STATE；越界或地址加法/末端溢出返回 DMA_TRANSLATION；length 为 0 合法，地址保持 0。
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

    // 功能：判断 [first_iova, end_iova) 是否与 ACTIVE 分配的 IOVA 范围重叠。
    // 输入/输出及副作用：只读账本；返回 bit。
    // 失败/边界：无。
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

    // 功能：在恒等 IOVA 或游标模式下选出对齐后的 IOVA 与新游标候选。
    // 输入/输出及副作用：selected_iova/committed_cursor 输出；不提交 next_iova，调用方成功后再提交。
    // 失败/边界：地址/游标/对齐/末端溢出或与 ACTIVE mapping 重叠返回 RESOURCE_EXHAUSTED；alignment 须为非零 2 的幂。
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

    // 功能：从 host_mem 分配 backing，选 IOVA，构造 mapping 并登记账本。
    // 输入/输出及副作用：mapping 先置 null；成功后登记并锁定 IOVA 配置；失败路径释放已分配的 backing。
    // 失败/边界：context 为空/校验失败、mem 未配置、IOVA 配置已锁定后被改、size/alignment/direction 非法、分配失败或克隆失败时返回错误。
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
      status = normalize_adapter_status(
        request_context.validate(),
        "DMA request validation"
      );
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

      status = normalize_adapter_status(
        choose_iova(
          backing_address,
          size,
          alignment,
          selected_iova,
          committed_cursor
        ),
        "IOVA selection"
      );
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
      status = normalize_adapter_status(
        allocated_mapping.initialize_allocation_identity(release_seal),
        "allocation identity initialization"
      );
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
      allocated_mapping.route = request_context.route;
      allocated_mapping.route_valid = request_context.route_valid;
      allocated_mapping.reset_epoch = request_context.reset_epoch;
      allocated_mapping.epoch_valid = request_context.epoch_valid;
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

      status = normalize_adapter_status(
        allocated_mapping.make_authority_snapshot(authority),
        "allocation authority snapshot"
      );
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

    // 功能：把用户 VA 范围按页 pin，并为每页从 host_mem 申请 backing 与 IOVA。
    // 输入/输出及副作用：umem 为输出；成功登记 UMEM 记录与各页回收地址。
    // 失败/边界：mem 未配置或 super.pin_umem 失败即返回；某页分配失败时逆序 free 已分配页并 unpin，umem 置 null。
    virtual function rdma_status pin_umem(
      rdma_function_handle function_h,
      longint unsigned user_va,
      longint unsigned length,
      output rdma_umem umem
    );
      rdma_status status;
      rdma_host_mem_umem_record record;
      bit [63:0] backing_address;

      umem = null;
      if (mem == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "host_mem API is not configured");
      status = normalize_adapter_status(
        super.pin_umem(function_h, user_va, length, umem),
        "UMEM pin"
      );
      if (!status.ok()) return status;
      record = rdma_host_mem_umem_record::type_id::create(
        $sformatf("umem_allocation_%0d", umem_allocations.size()));
      if (record == null) begin
        umem.unpin_pages();
        umem = null;
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "UMEM allocation record creation failed");
      end
      record.umem = umem;
      record.backing_mem = mem;
      foreach (umem.pages[index]) begin
        backing_address = mem.alloc(umem.page_size, umem.page_size,
                                    `__FILE__, `__LINE__);
        if (backing_address == 64'hffff_ffff_ffff_ffff) begin
          for (int rollback = record.backing_addresses.size() - 1;
               rollback >= 0; rollback--)
            mem.free(record.backing_addresses[rollback],
                     `__FILE__, `__LINE__);
          umem.unpin_pages();
          umem = null;
          return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "host_mem UMEM page allocation failed");
        end
        record.backing_addresses.push_back(backing_address);
        umem.pages[index].iova.value = backing_address;
        umem.pages[index].backing_addr.value = backing_address;
      end
      record.active = 1'b1;
      umem_allocations.push_back(record);
      return rdma_status::success();
    endfunction

    // 功能：先 unpin UMEM，再逆序回收其页 backing 并置记录 inactive。
    // 输入/输出及副作用：成功首次调用更新 UMEM 生命周期并 free 页；失败时不改 backing/active。
    // 失败/边界：umem 为空返回 INVALID_ARGUMENT；下游 unpin 失败则保留 backing 供重试；重复调用幂等不重复 free；未登记的转交 super。
    virtual function rdma_status unpin_umem(rdma_umem umem);
      rdma_status status;

      if (umem == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "UMEM to unpin is null");
      foreach (umem_allocations[index]) begin
        if (umem_allocations[index] == null ||
            umem_allocations[index].umem != umem)
          continue;
        if (!umem_allocations[index].active)
          return rdma_status::success("UMEM backing was already released");

        // 先完成 UMEM 状态迁移；只有成功才允许提交 backing free，避免
        // null/error 返回造成“页已 free、UMEM 仍 pinned”的半提交状态。
        status = normalize_adapter_status(
          umem.unpin_pages(),
          "UMEM unpin"
        );
        if (!status.ok())
          return status;

        for (int rollback = umem_allocations[index].backing_addresses.size() - 1;
             rollback >= 0; rollback--)
          umem_allocations[index].backing_mem.free(
            umem_allocations[index].backing_addresses[rollback],
            `__FILE__, `__LINE__);
        umem_allocations[index].active = 1'b0;
        return rdma_status::success();
      end
      return super.unpin_umem(umem);
    endfunction

    // 功能：校验 mapping 与范围后向其 backing 写入数据。
    // 输入/输出及副作用：写 backing_mem，不改账本。
    // 失败/边界：mapping/范围校验失败返回对应错误；data 为空只做校验。
    virtual function rdma_status write(
      rdma_dma_mapping mapping,
      longint unsigned offset,
      byte data[]
    );
      int allocation_index;
      bit [63:0] backing_address;
      rdma_status status;

      status = normalize_adapter_status(
        validate_mapping(mapping, allocation_index),
        "mapping validation"
      );
      if (!status.ok())
        return status;
      status = normalize_adapter_status(
        validate_range(
          allocations[allocation_index],
          offset,
          data.size(),
          backing_address
        ),
        "write range validation"
      );
      if (!status.ok())
        return status;
      if (data.size() == 0)
        return rdma_status::success();
      allocations[allocation_index].backing_mem.write_mem(
        backing_address, data, `__FILE__, `__LINE__
      );
      return rdma_status::success();
    endfunction

    // 功能：设备 DMA 地址解析：在 ACTIVE allocation 中找覆盖 [iova, iova+size) 的映射。
    // 输入/输出及副作用：mapping/offset 输出；只读。
    // 失败/边界：无覆盖的单一映射返回 DMA_TRANSLATION。
    virtual function rdma_status find_iova(
      bit [63:0] iova,
      int unsigned size,
      output rdma_dma_mapping mapping,
      output longint unsigned offset
    );
      mapping = null;
      offset = 0;
      foreach (allocations[i]) begin
        if (allocations[i] == null || !allocations[i].active || allocations[i].authority == null)
          continue;
        if (iova >= allocations[i].authority.iova.value &&
            {1'b0, iova} + size <=
            {1'b0, allocations[i].authority.iova.value} + allocations[i].authority.size) begin
          mapping = allocations[i].authority;
          offset = iova - allocations[i].authority.iova.value;
          return rdma_status::success();
        end
      end
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "device IOVA is not mapped");
    endfunction

    // 功能：校验 mapping 与范围后从其 backing 读取数据。
    // 输入/输出及副作用：data 先清空，成功时填充。
    // 失败/边界：校验失败返回错误；size 为 0 直接成功；读回长度不符返回 UNKNOWN_HW_ERROR 并清空 data。
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
      status = normalize_adapter_status(
        validate_mapping(mapping, allocation_index),
        "mapping validation"
      );
      if (!status.ok())
        return status;
      status = normalize_adapter_status(
        validate_range(
          allocations[allocation_index],
          offset,
          size,
          backing_address
        ),
        "read range validation"
      );
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

    // 功能：释放 mapping：先标记 seal 完成，再用账本内权威地址 free backing 并置 RELEASED。
    // 输入/输出及副作用：更新账本项与传入 mapping 的 state；free 只依据权威地址，不信任调用方字段。
    // 失败/边界：mapping 校验失败、类型丢失或 seal 标记失败返回错误，不 free。
    virtual function rdma_status \release (rdma_dma_mapping mapping);
      int allocation_index;
      rdma_host_mem_mapping concrete_mapping;
      rdma_status status;

      status = normalize_adapter_status(
        validate_mapping(mapping, allocation_index),
        "mapping validation"
      );
      if (!status.ok())
        return status;
      if (!$cast(concrete_mapping, mapping) || concrete_mapping == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "validated host memory mapping lost its concrete type"
        );
      // Functions cannot consume time, so sealing completion and freeing the
      // backing are one adapter operation.  The exact seal is never exposed.
      status = rdma_status::nonnull(
        concrete_mapping.mark_release_complete(release_seal),
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

    // 功能：只读确认 mapping 精确命中本 adapter 唯一的 active 分配且 seal 未完成。
    // 输入/输出及副作用：只读账本与 identity，不 seal/free，不改 mapping。
    // 失败/边界：异型、非 active、未知/跨 adapter、identity 重复、已释放、无 backing manager 或 seal 已完成均拒绝。
    virtual function rdma_status validate_failure_atomic_release(
      rdma_dma_mapping mapping
    );
      rdma_host_mem_mapping concrete_mapping;
      rdma_status status;
      int allocation_index;
      int unsigned match_count;
      bit release_complete;

      if (!$cast(concrete_mapping, mapping) || concrete_mapping == null)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "failure-atomic host mapping has no allocation identity"
        );
      if (concrete_mapping.state != RDMA_MAPPING_ACTIVE)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "failure-atomic host mapping is not active"
        );

      allocation_index = -1;
      match_count = 0;
      foreach (allocations[i]) begin
        if (allocations[i] != null && allocations[i].authority != null &&
            allocations[i].authority.same_allocation(concrete_mapping)) begin
          allocation_index = i;
          match_count++;
        end
      end
      if (match_count == 0)
        return rdma_status::make(
          RDMA_SC_DMA_TRANSLATION,
          "failure-atomic host mapping is not owned by this adapter"
        );
      if (match_count != 1)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "failure-atomic host mapping identity is ambiguous"
        );
      if (!allocations[allocation_index].active ||
          allocations[allocation_index].authority.state !=
            RDMA_MAPPING_ACTIVE)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "failure-atomic host allocation has already been released"
        );
      if (allocations[allocation_index].backing_mem == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "failure-atomic host allocation has no backing manager"
        );

      release_complete = 1'b0;
      status = concrete_mapping.release_completion_status(release_complete);
      if (status == null)
        return rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "failure-atomic host release status is null"
        );
      if (!status.ok())
        return status;
      if (release_complete)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "failure-atomic host release is already complete"
        );
      return rdma_status::success();
    endfunction

    // 功能：仅依据 allocation identity 释放 backing，供 router 在 manager 返回畸形字段时回滚。
    // 输入/输出及副作用：成功更新账本、backing 与 mapping 状态；不依赖可变 route/geometry 字段。
    // 失败/边界：先过 validate_failure_atomic_release；类型丢失、identity 变化或 seal 标记失败返回错误；不按不可信地址 free。
    virtual function rdma_status release_opaque(rdma_dma_mapping mapping);
      rdma_host_mem_mapping concrete_mapping;
      rdma_status status;
      int allocation_index;
      int unsigned match_count;

      status = normalize_adapter_status(
        validate_failure_atomic_release(mapping),
        "failure-atomic release validation"
      );
      if (!status.ok())
        return status;
      if (!$cast(concrete_mapping, mapping) || concrete_mapping == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "validated opaque host mapping lost its concrete type"
        );
      allocation_index = -1;
      match_count = 0;
      foreach (allocations[i]) begin
        if (allocations[i] != null && allocations[i].authority != null &&
            allocations[i].authority.same_allocation(concrete_mapping)) begin
          allocation_index = i;
          match_count++;
        end
      end
      if (match_count != 1 || allocation_index < 0)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "validated opaque host mapping identity changed"
        );
      status = concrete_mapping.mark_release_complete(release_seal);
      if (status == null)
        return rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "opaque host release completion marking returned null"
        );
      if (!status.ok())
        return status;
      allocations[allocation_index].backing_mem.free(
        allocations[allocation_index].authority.backing_addr.value,
        `__FILE__, `__LINE__
      );
      allocations[allocation_index].active = 1'b0;
      allocations[allocation_index].authority.state = RDMA_MAPPING_RELEASED;
      concrete_mapping.state = RDMA_MAPPING_RELEASED;
      return rdma_status::success();
    endfunction

    // host_mem leak_check is manager-global.  leak_count is adapter-owner
    // local; callers should isolate or first release unrelated manager users
    // when they require a pristine global host_mem report.
    // 功能：统计仍 active 的 mapping/UMEM 数，对各 backing manager 各做一次 leak_check。
    // 输入/输出及副作用：leak_count 输出；调用 host_mem.leak_check（去重）。
    // 失败/边界：mem 未配置返回 INVALID_STATE；存在 active 分配返回 INVALID_STATE。
    function rdma_status check_leaks(output int unsigned leak_count);
      host_mem_pkg::host_mem_api checked_mem[$];
      bit already_checked;

      leak_count = 0;
      foreach (allocations[i]) begin
        if (allocations[i] != null && allocations[i].active)
          leak_count++;
      end
      foreach (umem_allocations[i]) begin
        if (umem_allocations[i] != null && umem_allocations[i].active)
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
      foreach (umem_allocations[i]) begin
        if (umem_allocations[i] == null || umem_allocations[i].backing_mem == null)
          continue;
        already_checked = 1'b0;
        foreach (checked_mem[j]) begin
          if (checked_mem[j] == umem_allocations[i].backing_mem) begin
            already_checked = 1'b1;
            break;
          end
        end
        if (!already_checked) begin
          umem_allocations[i].backing_mem.leak_check(`__FILE__, `__LINE__);
          checked_mem.push_back(umem_allocations[i].backing_mem);
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
