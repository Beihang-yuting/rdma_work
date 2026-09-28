// 目录：核心执行层 core/rdma_resource_manager.sv。
// 职责：唯一拥有 resource registry、recovery、allocator、incarnation/generation 账本；
//   对外提供 detached 查询与资源生命周期提交，不执行 CMQ、DMA 或队列数据传输。
// 依赖：types/model 值契约、resource transaction candidate 和 allocator/dependency policy。
// 所有权与生命周期：manager 拥有账本快照，incarnation tombstone 在释放后保留；
//   外部 mapping/backing 仅借用 adapter 的不透明 authority，不接管其生命周期。
// 设计：外部投影/完成证明位于锁外，最终 mutation 在短 guard 内按冻结 epoch/source 提交。
//   schema 规范化保留业务值；查询不隐式发布快照，避免重入读操作覆盖后来的 mutation。
//   registry replacement 的 epoch/source 是必填契约；普通生命周期在入口冻结 epoch，
//   完成 lookup/schema 后冻结 canonical source，exact-old QP 则在 fallback 投影前冻结 source。
//   reservation 补偿区分独占回滚与过期返还：仅前者恢复游标/serial/binding，后者只归还
//   本次 local ID，不能撤销窗口内其它已成功或仍在途的分配；所有补偿仍由 manager 执行。
//   allocator admission 在首次外部调用前冻结 epoch；binding 投影在锁外准备，首次登记与
//   ID/serial 消费在同一短提交中完成。准备失败无需补偿，不允许留下半登记的 authority。

class rdma_resource_manager extends uvm_object;
  `uvm_object_utils(rdma_resource_manager)

  // Registry keys are exactly function_uid:generation:kind:object_id.
  protected rdma_resource registry[string];
  protected bit staged_allocations[string];
  protected rdma_recovery_record recovery_records[string];
  // The caller-owned reference is only a monotonic generation observer.  All
  // identity and configuration are read from the immutable deep-copy snapshot.
  protected rdma_function_binding generation_sources[string];
  protected rdma_function_binding binding_snapshots[string];
  protected int unsigned generation_high_water[string];
  protected bit generation_exhausted[string];
  protected bit known_generations[string];
  protected bit retired_generations[string];
  // Exact incarnation ownership is retained after release.  Including the
  // generation prevents a later Function generation from replacing an older
  // tombstone.
  protected rdma_function_handle incarnation_owners[string];
  protected rdma_handle incarnation_handles[string];

  // Local IDs are reusable and independent for every resource kind.  The
  // 28-bit serial component of object_id is monotonic and never reused; the
  // upper nibble carries kind so changing only handle.kind cannot alias a live
  // object from another independent pool.
  protected int unsigned next_local_id[rdma_resource_kind_e];
  protected int unsigned free_local_ids[rdma_resource_kind_e][$];
  protected bit fresh_local_id_exhausted[rdma_resource_kind_e];
  protected int unsigned next_object_serial[rdma_resource_kind_e];
  // QPC sequence is an incarnation counter for a local QPN within one exact
  // Function generation.  Entries intentionally outlive QP finalization so a
  // reused QPN receives the next sequence value.
  protected bit [7:0] qp_sequences[string];
  // publication_epoch 是 manager 唯一 mutable registry/allocator 账本的乐观代际。
  // detached candidate 在 stage 时捕获该值；任何 reservation、rollback 或 publication
  // commit 都推进它，使跨外部调用窗口的旧 candidate 只能失败而不能覆盖新账本。
  protected longint unsigned publication_epoch;
  // mutation_guard 保护完成 detached validation 后的 registry/recovery 写入及 allocator
  // reservation 提交；锁内不能再调用 factory/adapter。外部 projection 与 admission
  // 不持锁，调用方的资源生命周期也不由这把锁接管，避免 callback 反向重入死锁。
  protected semaphore mutation_guard;

  // 功能：构造空 resource manager，初始化 publication_epoch=0 和单 token mutation_guard。
  // 输入/输出及副作用：name 传给 UVM 父类；本对象独占初始为空的 registry、allocator、
  //   generation/recovery 账本及 guard，不创建外部 adapter 或 backing。
  // 失败/边界：构造后可直接接受合法 active binding 的资源请求；空账本不提供默认 Function
  //   authority，调用方仍须通过 create_* 的 admission，不能凭默认 handle 访问资源。
  function new(string name = "rdma_resource_manager");
    super.new(name);
    publication_epoch = '0;
    mutation_guard = new(1);
  endfunction

  // 功能：advance_publication_epoch 为 resource manager 的一次 allocator、registry 或
  // incarnation 账本 mutation 推进乐观并发代际，供 detached publication candidate 做
  // stage→commit 的新鲜度校验。
  // 输入/输出及副作用：无显式输入；函数只更新本对象 publication_epoch，不读取或取得
  // 外部 adapter、resource 或 binding 所有权，也不发布任何 registry 条目。
  // 失败/边界：64 位代际到达全一值后保持饱和，避免回绕导致旧 candidate 误判为新；该
  // helper 不负责回滚，调用方必须只在已确认的 mutation 边界调用。
  protected function void advance_publication_epoch();
    if (publication_epoch != '1)
      publication_epoch++;
  endfunction

  // 功能：判断 valid_kind 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：kind（输入）；valid_kind 读取 kind 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：valid_kind 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected function bit valid_kind(rdma_resource_kind_e kind);
    return rdma_resource_allocator_policy::valid_kind(kind);
  endfunction

  // 功能：lifecycle_queue_kind 集中判定哪些资源由 queue backing plan
  //   参与 QUIESCING/ERROR 生命周期恢复，供进度、恢复和错误发布分派共用同一分类。
  // 输入/输出及副作用：kind 为资源类型输入；函数只读取枚举并返回 bit，不修改
  //   registry、recovery、状态或外部 backing，也不取得任何资源所有权。
  // 失败/边界：仅 CQ、SRQ、CEQ、AEQ 返回 1；FUNCTION、PD、MR、QP、CMQ 以及
  //   未定义枚举值均返回 0。该分类比 valid_kind 的“可登记资源”范围更窄，不能替代
  //   kind 合法性校验或资源存在性校验。
  protected function bit lifecycle_queue_kind(rdma_resource_kind_e kind);
    return kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                        RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ};
  endfunction

  // 功能：在 rdma_resource_manager 中，local_id_limit 根据资源 kind 返回 Function 内可分配 local ID 的上限，供容量和越界检查使用。
  // 输入/输出及副作用：kind（输入）；local_id_limit 读取 kind 并使用字段 ；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：local_id_limit 按 case(kind) 的固定映射计算 int unsigned（RDMA_RESOURCE_PD→16'hffff；RDMA_RESOURCE_MR→24'hff_ffff；RDMA_RESOURCE_CQ→21'h1f_ffff；RDMA_RESOURCE_QP→21'h1f_ffff；其余 case 分支按源码继续映射；default→32'hffff_ffff）；未列出的输入走 default，不修改运行时账本。
  protected function int unsigned local_id_limit(
    rdma_resource_kind_e kind
  );
    return rdma_resource_allocator_policy::local_id_limit(kind);
  endfunction

  // 功能：local_id_status 优先检查 free-list 首项，其次检查 fresh 游标是否仍可编码。
  // 输入/输出及副作用：kind 指定已验证的资源池，has_free_id 输出当前是否有空闲 ID，
  //   返回容量 status；不消费 ID，但 status factory 可能重入，输出不是已提交的预留。
  // 失败/边界：free-list 首项越过硬件宽度、fresh exhausted 或游标超限返回
  //   RESOURCE_EXHAUSTED；caller 必须在消费前复核 admission epoch，不能直接使用旧观察值。
  protected function rdma_status local_id_status(
    rdma_resource_kind_e kind,
    output bit has_free_id
  );
    int unsigned limit;

    limit = local_id_limit(kind);
    has_free_id = free_local_ids.exists(kind) &&
                  free_local_ids[kind].size() != 0;
    if (has_free_id) begin
      if (free_local_ids[kind][0] > limit)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "resource free-list local ID exceeds the hardware width"
        );
      return rdma_status::success();
    end
    if ((fresh_local_id_exhausted.exists(kind) &&
         fresh_local_id_exhausted[kind]) || next_local_id[kind] > limit)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "resource local ID pool is exhausted");
    return rdma_status::success();
  endfunction

  // 功能：consume_local_id 消费指定池的首个空闲 ID，或推进 fresh 游标并标记最大 ID 耗尽。
  // 输入/输出及副作用：kind/has_free_id 指定已准入池和来源，local_id 输出消费的 ID；
  //   只修改 free_local_ids、next_local_id、fresh_local_id_exhausted，不执行 factory。
  // 失败/边界：仅共同 reservation commit 持 guard 且 epoch/容量检查仍有效时调用；
  //   不自行处理空 free-list 或超限游标，最大 ID 不做加一，以免 32 位回绕。
  protected function void consume_local_id(
    rdma_resource_kind_e kind,
    bit has_free_id,
    output int unsigned local_id
  );
    int unsigned limit;

    if (has_free_id) begin
      local_id = free_local_ids[kind].pop_front();
      return;
    end
    limit = local_id_limit(kind);
    local_id = next_local_id[kind];
    if (local_id == limit)
      fresh_local_id_exhausted[kind] = 1'b1;
    else
      next_local_id[kind]++;
  endfunction

  // 功能：在 rdma_resource_manager 中，resource_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：handle（输入）；resource_key 读取 handle 并使用输入参数和固定枚举/常量；函数返回 string，不取得调用方资源所有权。
// 失败/边界：resource_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function string resource_key(rdma_handle handle);
    return $sformatf("%016h:%08h:%01h:%08h", handle.function_uid,
                     handle.generation, handle.kind, handle.object_id);
  endfunction

  // 功能：在 rdma_resource_manager 中，incarnation_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：handle（输入）；incarnation_key 读取 handle 并使用输入参数和固定枚举/常量；函数返回 string，不取得调用方资源所有权。
// 失败/边界：incarnation_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function string incarnation_key(rdma_handle handle);
    return resource_key(handle);
  endfunction

  // 功能：在 rdma_resource_manager 中，function_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：owner（输入）；function_key 读取 owner 并使用输入参数和固定枚举/常量；函数返回 string，不取得调用方资源所有权。
// 失败/边界：function_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function string function_key(rdma_function_handle owner);
    return $sformatf("%016h:%08h", owner.function_uid, owner.object_id);
  endfunction

  // 功能：在 rdma_resource_manager 中，function_generation_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：owner（输入）；function_generation_key 读取 owner 并使用输入参数和固定枚举/常量；函数返回 string，不取得调用方资源所有权。
// 失败/边界：function_generation_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function string function_generation_key(
    rdma_function_handle owner
  );
    return $sformatf("%016h:%08h:%08h", owner.function_uid,
                     owner.object_id, owner.generation);
  endfunction

  // 功能：在 rdma_resource_manager 中，qp_sequence_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：owner（输入）、local_qpn（输入）；qp_sequence_key 读取 owner、local_qpn 并使用输入参数和固定枚举/常量；函数返回 string，不取得调用方资源所有权。
// 失败/边界：qp_sequence_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function string qp_sequence_key(
    rdma_function_handle owner,
    int unsigned local_qpn
  );
    return $sformatf("%016h:%08h:%08h:%06h", owner.function_uid,
                     owner.object_id, owner.generation, local_qpn);
  endfunction

  // Public carriers may be compatible subclasses, but only fields declared by
  // the built-in model are authoritative.  Borrowed carrier graphs are
  // structurally projected into direct-new built-in storage without invoking
  // their virtual clone/copy hooks.  An owned DMA mapping is the explicit
  // exception: its concrete clone carries opaque adapter release authority and
  // is accepted only through the checked contract below.  Future extension
  // support requires another explicit trusted adapter here.
  // 功能：在 rdma_resource_manager 中，project_handle_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_handle_value 读取 source、copy_label、result 并使用字段 result、result_function、result.kind、result.function_uid、result.object_id、result.generation，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_handle_value 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status project_handle_value(
    rdma_handle source,
    string copy_label,
    output rdma_handle result
  );
    rdma_function_handle source_function;
    rdma_function_handle result_function;

    result = null;
    if (source == null)
      return rdma_status::success();
    if (source.kind == RDMA_RESOURCE_FUNCTION) begin
      if (!$cast(source_function, source))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          {copy_label, " Function handle is structurally incompatible"}
        );
      result_function = new({copy_label, "_function_handle"});
      result = result_function;
    end
    else begin
      result = new({copy_label, "_handle"});
    end
    result.kind = source.kind;
    result.function_uid = source.function_uid;
    result.object_id = source.object_id;
    result.generation = source.generation;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_function_handle_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_function_handle_value 读取 source、copy_label、result 并使用字段 result、result.kind、result.function_uid、result.object_id、result.generation，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_function_handle_value 先检查 source == null，再返回 rdma_status::success()；拒绝分支不提交部分状态，也不隐式重试。
  protected function rdma_status project_function_handle_value(
    rdma_function_handle source,
    string copy_label,
    output rdma_function_handle result
  );
    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_function_handle"});
    result.kind = source.kind;
    result.function_uid = source.function_uid;
    result.object_id = source.object_id;
    result.generation = source.generation;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_mapping_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_mapping_value 读取 source、copy_label、result 并使用字段 result、status、result.requester_bdf、result.pasid_valid、result.pasid、result.dma_domain_valid、result.dma_domain_id、result.backing_addr，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_mapping_value 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status project_mapping_value(
    rdma_dma_mapping source,
    string copy_label,
    output rdma_dma_mapping result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_mapping"});
    status = project_function_handle_value(
      source.function_h, {copy_label, "_function"}, result.function_h
    );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    status = project_handle_value(source.owner_h, {copy_label, "_owner"},
                                  result.owner_h);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.requester_bdf = source.requester_bdf;
    result.pasid_valid = source.pasid_valid;
    result.pasid = source.pasid;
    result.dma_domain_valid = source.dma_domain_valid;
    result.dma_domain_id = source.dma_domain_id;
    // Route 与 reset epoch 是 mapping authority 的一部分。若 detached
    // projection 丢失这两个字段，CQ resize recovery 无法证明旧 backing
    // 仍属于原 Host/Function，也不能安全执行 opaque cleanup。
    result.route = source.route;
    result.route_valid = source.route_valid;
    result.reset_epoch = source.reset_epoch;
    result.epoch_valid = source.epoch_valid;
    result.backing_addr = source.backing_addr;
    result.iova = source.iova;
    result.size = source.size;
    result.direction = source.direction;
    result.permissions = source.permissions;
    result.state = source.state;
    return rdma_status::success();
  endfunction

  // 功能：same_mapping_handle_value 为 mapping/HMC 值比较提供 nullable handle
  //       identity seam，并转发到 resource manager 的 canonical handle 比较。
  // 输入/输出及副作用：lhs、rhs（输入）是非拥有 handle 引用；只读取 kind、
  //       function_uid、object_id、generation，返回 bit，不修改 handle、mapping、
  //       runtime、账本或外部 adapter，也不取得任何资源所有权。
  // 失败/边界：lhs 与 rhs 同为 null 返回 1；仅一侧为 null 返回 0；两侧非空时
  //       四个字段任一 `==` 不等返回 0。该 seam 不执行 $isunknown，也不判断
  //       authority、对象 alias 或 generation 新鲜度，调用方须保留自己的门禁。
  protected function bit same_mapping_handle_value(
    rdma_handle lhs,
    rdma_handle rhs
  );
    return same_handle_instance(lhs, rhs);
  endfunction

  // 功能：same_hmc_ref_value 比较两个 HMC reference 的 owner、对象类型、地址、大小、
  //       PBLE index 元数据、所有权和释放完成标志，形成跨 queue/context 比较共用的值契约。
  // 输入/输出及副作用：lhs、rhs（输入 HMC reference）；函数只读 owner、object_kind、address、
  //       size、first_pbl_index、index_valid、ownership 和 release_complete，返回 bit，
  //       不修改 reference、mapping state、账本或外部资源。
  // 失败/边界：任一 reference 为空时按值比较规则返回 lhs==rhs；owner 为空时交给
  //       same_mapping_handle_value 保持原 null/null 相等语义；该 helper 不比较 mapping state，
  //       调用方仍须在使用前完成各自的 null、slot-token、completion-authority 和 release 前置校验。
  protected function bit same_hmc_ref_value(
    rdma_hmc_ref lhs,
    rdma_hmc_ref rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return same_mapping_handle_value(lhs.owner, rhs.owner) &&
           lhs.object_kind == rhs.object_kind &&
           lhs.address.value == rhs.address.value &&
           lhs.size == rhs.size &&
           lhs.first_pbl_index == rhs.first_pbl_index &&
           lhs.index_valid == rhs.index_valid &&
           lhs.ownership == rhs.ownership &&
           lhs.release_complete == rhs.release_complete;
  endfunction

  // 功能：在 rdma_resource_manager 中比较释放 authority 的全部值字段，包括
  //       Function/owner、DMA 参数、完整 Host/root/segment/BDF route 和 reset epoch。
  // 输入/输出及副作用：lhs/rhs（输入 mapping）；只读比较对象并返回 bit，不更新
  //       runtime、账本或外部 adapter。
  // 失败/边界：任一对象为空、route/epoch 有缺失或任一 authority 字段不一致时返回
  //       0；即使 mapping.state 不同也由调用方决定是否使用该值比较。
  protected function bit same_mapping_release_fields(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    return same_mapping_handle_value(lhs.function_h, rhs.function_h) &&
           lhs.requester_bdf == rhs.requester_bdf &&
           lhs.pasid_valid == rhs.pasid_valid &&
           lhs.pasid == rhs.pasid &&
           lhs.dma_domain_valid == rhs.dma_domain_valid &&
           lhs.dma_domain_id == rhs.dma_domain_id &&
           lhs.route_valid == rhs.route_valid &&
           lhs.route.host_topology_key == rhs.route.host_topology_key &&
           lhs.route.root_id == rhs.route.root_id &&
           lhs.route.segment == rhs.route.segment &&
           rdma_bdf_same(lhs.route.bdf, rhs.route.bdf) &&
           lhs.epoch_valid == rhs.epoch_valid &&
           lhs.reset_epoch == rhs.reset_epoch &&
           lhs.backing_addr.value == rhs.backing_addr.value &&
           lhs.iova.value == rhs.iova.value &&
           lhs.size == rhs.size &&
           lhs.direction == rhs.direction &&
           lhs.permissions == rhs.permissions &&
           same_mapping_handle_value(lhs.owner_h, rhs.owner_h);
  endfunction

  // 功能：same_mapping_value 在完整 release-authority 值相等的基础上继续比较
  //   mapping.state，供需要精确区分 ACTIVE/RELEASED 的 registry 快照校验使用。
  // 输入/输出及副作用：lhs、rhs（输入）为只读 mapping 引用；函数比较 Function/owner、
  //   requester/DMA、route/epoch、address/IOVA/size/direction/permissions 和 state，返回 bit，
  //   不更新 manager 账本、mapping 或外部 adapter。
  // 失败/边界：两侧同时为 null 时返回 1，只有一侧为 null 或任一 authority/state 字段
  //   不一致时返回 0；动态 subtype 不参与相等判定，也不会触发隐式投影或完成查询。
  protected function bit same_mapping_value(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return same_mapping_release_fields(lhs, rhs) &&
           lhs.state == rhs.state;
  endfunction

  // Recovery-only mappings expose a public state field that the adapter may
  // update while sealing the opaque release capability.  The state on the
  // resource and recovery projections can therefore legitimately differ
  // (ACTIVE versus RELEASED) even though all authority-bearing values remain
  // identical.  Completion is checked through the adapter query separately.
  // 功能：same_recovery_mapping_value 比较 recovery projection 的完整 release authority，
  //   但刻意忽略公开 state；opaque release completion 由 adapter query 另行证明。
  // 输入/输出及副作用：lhs、rhs（输入）为只读 mapping 引用；函数比较 Function/owner、
  //   requester/DMA、route/epoch、address/IOVA/size/direction/permissions，返回 bit，不修改
  //   manager、mapping 或外部完成状态。
  // 失败/边界：两侧同时为 null 时返回 1，只有一侧为 null 或任一 authority 字段不一致时
  //   返回 0；ACTIVE/RELEASED 不同本身不构成失败，调用方必须继续查询 opaque completion。
  protected function bit same_recovery_mapping_value(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return same_mapping_release_fields(lhs, rhs);
  endfunction

  // 功能：在 rdma_resource_manager 中，mapping_handles_detached 逐字段核对快照、嵌套引用和 authority 值，确认复制结果既等值又无可变别名。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；mapping_handles_detached 读取 lhs、rhs 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：mapping_handles_detached 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function bit mapping_handles_detached(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return (lhs.function_h == null || rhs.function_h == null ||
            lhs.function_h != rhs.function_h) &&
           (lhs.owner_h == null || rhs.owner_h == null ||
            lhs.owner_h != rhs.owner_h);
  endfunction

  // 功能：在 rdma_resource_manager 中，mapping_hook_value_intact 逐字段核对快照、嵌套引用和 authority 值，确认复制结果既等值又无可变别名。
  // 输入/输出及副作用：current（输入）、saved（输入）、expected_type（输入）；mapping_hook_value_intact 读取 current、saved、expected_type 并使用字段 current_type；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：mapping_hook_value_intact 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function bit mapping_hook_value_intact(
    rdma_dma_mapping current,
    rdma_dma_mapping saved,
    uvm_object_wrapper expected_type
  );
    uvm_object_wrapper current_type;

    if (current == null || saved == null || current == saved ||
        expected_type == null)
      return 1'b0;
    current_type = current.get_object_type();
    return current_type != null && current_type == expected_type &&
           same_mapping_value(current, saved) &&
           mapping_handles_detached(current, saved);
  endfunction

  // 功能：在 rdma_resource_manager 中，owned_mapping_hook_graph_intact 逐字段核对快照、嵌套引用和 authority 值，确认复制结果既等值又无可变别名。
  // 输入/输出及副作用：source（输入）、result（输入）、saved_value（输入）、source_type（输入）、authority_snapshot（输入）、saved_authority（输入）、authority_type（输入）；owned_mapping_hook_graph_intact 读取 source、result、saved_value、source_type、authority_snapshot、saved_authority、authority_type 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：owned_mapping_hook_graph_intact 只读输入并返回 bit；边界由函数体现有分支决定，不修改状态或转移资源。
  protected function bit owned_mapping_hook_graph_intact(
    rdma_dma_mapping source,
    rdma_dma_mapping result,
    rdma_dma_mapping saved_value,
    uvm_object_wrapper source_type,
    rdma_dma_mapping authority_snapshot,
    rdma_dma_mapping saved_authority,
    uvm_object_wrapper authority_type
  );
    return source != result && source != authority_snapshot &&
           result != authority_snapshot &&
           mapping_hook_value_intact(source, saved_value, source_type) &&
           mapping_hook_value_intact(result, saved_value, source_type) &&
           mapping_hook_value_intact(authority_snapshot, saved_authority,
                                     authority_type) &&
           mapping_handles_detached(source, result) &&
           mapping_handles_detached(source, authority_snapshot) &&
           mapping_handles_detached(result, authority_snapshot);
  endfunction

  // An owned mapping is also the adapter's release capability.  Preserve its
  // concrete value type while treating clone() as an untrusted boundary: the
  // clone must be registered, exact-type, detached, and value preserving.
  // 功能：在 rdma_resource_manager 中，clone_owned_mapping_value 将 rhs 中 rdma_resource_manager 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；clone_owned_mapping_value 读取 source、copy_label、result 并使用字段 result、status、source_type、authority_type、cloned_object、result_type，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：clone_owned_mapping_value 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status clone_owned_mapping_value(
    rdma_dma_mapping source,
    string copy_label,
    output rdma_dma_mapping result
  );
    rdma_dma_mapping saved_value;
    rdma_dma_mapping authority_snapshot;
    rdma_dma_mapping saved_authority;
    rdma_status status;
    uvm_object cloned_object;
    uvm_object_wrapper source_type;
    uvm_object_wrapper result_type;
    uvm_object_wrapper authority_type;

    result = null;
    if (source == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping is null"}
      );
    status = project_mapping_value(source, {copy_label, "_saved"},
                                   saved_value);
    if (!status.ok())
      return status;
    source_type = source.get_object_type();
    if (source_type == null ||
        source_type == rdma_dma_mapping::get_type())
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping type is not a registered subtype"}
      );
    status = source.snapshot_release_authority(authority_snapshot);
    if (status == null || !status.ok() || authority_snapshot == null ||
        authority_snapshot == source ||
        !same_mapping_value(source, saved_value)) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping authority snapshot is unsupported or invalid"}
      );
    end
    authority_type = authority_snapshot.get_object_type();
    status = project_mapping_value(
      authority_snapshot, {copy_label, "_saved_authority"}, saved_authority
    );
    if (status == null || !status.ok() || authority_type == null ||
        authority_type != source_type ||
        !mapping_hook_value_intact(authority_snapshot, saved_authority,
                                   authority_type) ||
        !mapping_handles_detached(source, authority_snapshot)) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping authority snapshot changed value, type, or aliases"}
      );
    end
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(result, cloned_object) ||
        result == source) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping clone contract failed"}
      );
    end
    result_type = result.get_object_type();
    if (result_type == null || result_type != source_type ||
        !owned_mapping_hook_graph_intact(
          source, result, saved_value, source_type,
          authority_snapshot, saved_authority, authority_type
        )) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping clone changed type, value, or aliases"}
      );
    end
    status = source.release_authority_status(authority_snapshot);
    if (status == null || !status.ok() ||
        !owned_mapping_hook_graph_intact(
          source, result, saved_value, source_type,
          authority_snapshot, saved_authority, authority_type
        )) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping source authority hook changed value, authority, or aliases"}
      );
    end
    status = result.release_authority_status(authority_snapshot);
    if (status == null || !status.ok() ||
        !owned_mapping_hook_graph_intact(
          source, result, saved_value, source_type,
          authority_snapshot, saved_authority, authority_type
        )) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " owned mapping result authority hook changed value, authority, or aliases"}
      );
    end
    return rdma_status::success();
  endfunction

  // Recovery may carry a detached copy of an owned mapping, but matching
  // public fields are not proof that it controls the same allocation.  Use an
  // opaque authority snapshot from the authoritative mapping and require the
  // recovery mapping to accept it, while retaining the same type, value, and
  // alias guards used by the owned clone boundary.
  // 功能：在 rdma_resource_manager 中由 same_owned_mapping_authority 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：authoritative（输入）、recovery（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_owned_mapping_authority 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_owned_mapping_authority(
    rdma_dma_mapping authoritative,
    rdma_dma_mapping recovery
  );
    rdma_dma_mapping saved_value;
    rdma_dma_mapping authority_snapshot;
    rdma_dma_mapping saved_authority;
    rdma_status status;
    uvm_object_wrapper mapping_type;
    uvm_object_wrapper authority_type;

    if (authoritative == null || recovery == null)
      return 1'b0;
    mapping_type = authoritative.get_object_type();
    status = project_mapping_value(
      authoritative, "owned authority correspondence value", saved_value
    );
    if (status == null || !status.ok() || mapping_type == null)
      return 1'b0;
    status = authoritative.snapshot_release_authority(authority_snapshot);
    if (status == null || !status.ok() || authority_snapshot == null)
      return 1'b0;
    authority_type = authority_snapshot.get_object_type();
    status = project_mapping_value(
      authority_snapshot, "owned authority correspondence snapshot",
      saved_authority
    );
    if (status == null || !status.ok() || authority_type == null ||
        authority_type != mapping_type ||
        !owned_mapping_hook_graph_intact(
          authoritative, recovery, saved_value, mapping_type,
          authority_snapshot, saved_authority, authority_type
        ))
      return 1'b0;
    status = authoritative.release_authority_status(authority_snapshot);
    if (status == null || !status.ok() ||
        !owned_mapping_hook_graph_intact(
          authoritative, recovery, saved_value, mapping_type,
          authority_snapshot, saved_authority, authority_type
        ))
      return 1'b0;
    status = recovery.release_authority_status(authority_snapshot);
    return status != null && status.ok() &&
           owned_mapping_hook_graph_intact(
             authoritative, recovery, saved_value, mapping_type,
             authority_snapshot, saved_authority, authority_type
           );
  endfunction

  // 功能：same_backing_segment_value 只读比较附加 backing segment 的角色、所有权、
  //   映射范围、逻辑偏移和 mapping 值，供 queue/QP backing 快照比较复用。
  // 输入/输出及副作用：lhs、rhs（输入）；只读取两个 segment 及其 mapping，不写入对象、
  //   账本或外部 adapter；返回 bit 表示字段是否逐项一致。
  // 失败/边界：任一 segment 句柄为 null 时返回 0（包括两者同时为 null），保持各 parent
  //   比较循环原有的空段拒绝语义；mapping 值不一致或任一字段不同也返回 0。
  protected function bit same_backing_segment_value(
    rdma_queue_backing_segment lhs,
    rdma_queue_backing_segment rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.role == rhs.role &&
           lhs.ownership == rhs.ownership &&
           lhs.mapping_offset == rhs.mapping_offset &&
           lhs.length == rhs.length &&
           lhs.logical_queue_offset == rhs.logical_queue_offset &&
           same_mapping_value(lhs.mapping, rhs.mapping);
  endfunction

  // 功能：在 rdma_resource_manager 中由 same_queue_backing_ref_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_queue_backing_ref_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_queue_backing_ref_value(
    rdma_queue_backing_ref lhs,
    rdma_queue_backing_ref rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.role != rhs.role || lhs.ownership != rhs.ownership ||
        lhs.mapping_offset != rhs.mapping_offset ||
        lhs.length != rhs.length ||
        lhs.logical_queue_offset != rhs.logical_queue_offset ||
        lhs.additional_segments.size() != rhs.additional_segments.size() ||
        !same_mapping_value(lhs.mapping, rhs.mapping))
      return 1'b0;
    foreach (lhs.additional_segments[i]) begin
      if (!same_backing_segment_value(lhs.additional_segments[i],
                                      rhs.additional_segments[i]))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：在 rdma_resource_manager 中由 same_owned_queue_backing_ref_authority 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：authoritative（输入）、recovery（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_owned_queue_backing_ref_authority 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_owned_queue_backing_ref_authority(
    rdma_queue_backing_ref authoritative,
    rdma_queue_backing_ref recovery
  );
    if (authoritative == null || recovery == null ||
        authoritative.ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
        recovery.ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
        authoritative.additional_segments.size() !=
          recovery.additional_segments.size() ||
        !same_owned_mapping_authority(authoritative.mapping,
                                      recovery.mapping))
      return 1'b0;
    foreach (authoritative.additional_segments[i]) begin
      if (authoritative.additional_segments[i] == null ||
          recovery.additional_segments[i] == null ||
          authoritative.additional_segments[i].ownership !=
            RDMA_OWNERSHIP_CONTROL_PLANE ||
          recovery.additional_segments[i].ownership !=
            RDMA_OWNERSHIP_CONTROL_PLANE ||
          !same_owned_mapping_authority(
            authoritative.additional_segments[i].mapping,
            recovery.additional_segments[i].mapping
          ))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：在 rdma_resource_manager 中由 same_queue_ring_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_queue_ring_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_queue_ring_value(
    rdma_queue_ring_layout lhs,
    rdma_queue_ring_layout rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.role != rhs.role ||
        lhs.entry_size_bytes != rhs.entry_size_bytes ||
        lhs.depth != rhs.depth || lhs.logical_bytes != rhs.logical_bytes ||
        lhs.storage_bytes != rhs.storage_bytes ||
        lhs.page_count != rhs.page_count ||
        lhs.initial_polarity != rhs.initial_polarity ||
        lhs.pages.size() != rhs.pages.size())
      return 1'b0;
    foreach (lhs.pages[i]) begin
      if (lhs.pages[i] == null || rhs.pages[i] == null ||
          lhs.pages[i].role != rhs.pages[i].role ||
          lhs.pages[i].mapping_offset != rhs.pages[i].mapping_offset ||
          lhs.pages[i].logical_page_offset !=
            rhs.pages[i].logical_page_offset ||
          lhs.pages[i].page_iova.value != rhs.pages[i].page_iova.value ||
          !same_mapping_value(lhs.pages[i].mapping, rhs.pages[i].mapping))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：same_context_authority_value 比较两个 context backing 共享的 slot-token、
  //       completion-authority、Function owner、资源定位和 HMC 值字段，集中维护
  //       context authority 的纯值相等契约，供释放恢复与 QP 计划比较复用。
  // 输入/输出及副作用：lhs、rhs（输入 context backing）；函数只读两份 backing、
  //       token、authority、owner 和 HMC reference，返回 bit，不写对象、账本、runtime
  //       或外部 adapter，也不取得资源所有权。
  // 失败/边界：lhs/rhs 同时为空按值相等返回 1，只有一侧为空返回 0；slot_token 的
  //       $cast 失败、completion_authority 缺失或指针不相同、owner/定位字段/HMC
  //       reference 任一不一致返回 0；HMC reference 的 release_complete 也属于其
  //       canonical 值。该 helper 不单独比较 context backing 自身的 release_complete，
  //       也不判断 completion_authority.complete；调用方必须保留各自的释放完成语义。
  protected function bit same_context_authority_value(
    rdma_context_backing_ref lhs,
    rdma_context_backing_ref rhs
  );
    rdma_queue_slot_token_contract lhs_token;
    rdma_queue_slot_token_contract rhs_token;

    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (!$cast(lhs_token, lhs.slot_token) || !$cast(rhs_token, rhs.slot_token) ||
        lhs_token.completion_authority == null ||
        rhs_token.completion_authority == null ||
        lhs_token.completion_authority !== rhs_token.completion_authority ||
        !same_handle_instance(lhs.owner, rhs.owner) ||
        lhs.resource_kind != rhs.resource_kind ||
        lhs.local_id != rhs.local_id ||
        lhs.shadow_pointer_base.value != rhs.shadow_pointer_base.value ||
        lhs.slot_length != rhs.slot_length ||
        lhs.shadow_view_offset != rhs.shadow_view_offset ||
        lhs.shadow_view_length != rhs.shadow_view_length ||
        lhs.hmc_ref == null || rhs.hmc_ref == null ||
        !same_hmc_ref_value(lhs.hmc_ref, rhs.hmc_ref))
      return 1'b0;
    return 1'b1;
  endfunction

  // 设计：queue context cleanup 的进度同时存在于 authoritative registry
  //   快照和 ERROR recovery 快照。两侧 context_ref 必须先证明 presence
  //   对称，再验证 slot-token 所携带的 opaque completion authority 以及
  //   owner、资源定位、shadow geometry 和 HMC 值；只有这份只读证明通过后，
  //   caller 才能在 detached candidate 上置位 release_complete 并原子提交。
  // 功能：queue_context_progress_authority_status 为 context cleanup progress
  //   建立 authoritative/recovery 两侧的只读 authority 前置条件，区分调用方
  //   传入的非法 authoritative context 与 ERROR recovery 已损坏或已漂移的 context。
  // 输入/输出及副作用：authoritative、recovery（输入 context backing 快照）、
  //   has_recovery（输入）；函数只读取两侧 context_ref、slot_token、completion_authority、
  //   canonical 定位字段和 release_complete，不写 registry、recovery_records、快照或
  //   外部 backing，也不取得资源所有权；返回 rdma_status 供 caller 决定是否提交。
  // 失败/边界：无 recovery 时保留原语义，authoritative 为空、已置位或 token/authority
  //   不合法返回 INVALID_ARGUMENT；有 recovery 时先拒绝两侧 context_ref presence 不对称，
  //   recovery 为空、已置位、token/authority 不合法或 canonical authority 与 authoritative
  //   不一致返回 INVALID_STATE。成功仅表示两侧都仍可推进，函数不会修改 release_complete。
  protected function rdma_status queue_context_progress_authority_status(
    rdma_context_backing_ref authoritative,
    rdma_context_backing_ref recovery,
    bit has_recovery
  );
    rdma_queue_slot_token_contract authoritative_token;
    rdma_queue_slot_token_contract recovery_token;

    if (!has_recovery) begin
      if (authoritative == null || authoritative.release_complete)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue context cleanup is absent or complete"
        );
      if (!$cast(authoritative_token, authoritative.slot_token) ||
          authoritative_token.completion_authority == null)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue context authority is invalid"
        );
      return rdma_status::success();
    end

    // 在任何字段解引用前先检查 presence parity。这里与上面的无 recovery
    // 分支刻意分开：ERROR queue 的 detached recovery context 缺失属于恢复状态
    // 破坏，不能据此伪造 context，也不能发布单侧进度。
    if ((authoritative == null) != (recovery == null))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "ERROR queue context presence diverged"
      );
    if (authoritative == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "queue context cleanup is absent or complete"
      );
    if (authoritative.release_complete)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "queue context cleanup is absent or complete"
      );
    if (recovery.release_complete)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "ERROR recovery queue context is already complete"
      );
    if (!$cast(authoritative_token, authoritative.slot_token) ||
        authoritative_token.completion_authority == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "queue context authority is invalid"
      );
    if (!$cast(recovery_token, recovery.slot_token) ||
        recovery_token.completion_authority == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "ERROR recovery queue context authority is invalid"
      );
    if (authoritative_token.completion_authority !==
          recovery_token.completion_authority ||
        !same_context_authority_value(authoritative, recovery))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "ERROR recovery queue context authority diverged"
      );
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中先复用 context authority 值比较，再确认
  //       candidate 的 completion authority 已 complete 且 backing 已 release，判断
  //       authoritative 与 candidate 是否可作为同一释放恢复记录。
  // 输入/输出及副作用：authoritative、candidate（输入）；对象、slot token 和 HMC
  //       reference 只读；返回 bit，不更新 runtime、账本或外部 adapter。
  // 失败/边界：两者同为空按值相等通过；单侧为空、token cast/authority/HMC 或共同
  //       字段不一致、candidate completion 未完成或 candidate.release_complete 为 0
  //       时返回 0，不抛出未处理异常，也不隐式改变 release 状态。
  protected function bit same_released_queue_context_value(
    rdma_context_backing_ref authoritative,
    rdma_context_backing_ref candidate
  );
    rdma_queue_slot_token_contract candidate_token;

    if (!same_context_authority_value(authoritative, candidate))
      return 1'b0;
    if (authoritative == null || candidate == null)
      return authoritative == candidate;
    if (!$cast(candidate_token, candidate.slot_token) ||
        candidate_token.completion_authority == null ||
        !candidate_token.completion_authority.complete ||
        !candidate.release_complete)
      return 1'b0;
    return 1'b1;
  endfunction

  // 功能：在 rdma_resource_manager 中，canonical_queue_reservation_release_recovery 规范化输入 key/恢复记录并检查必需字段，使同一语义对象只产生一种登记表示。
  // 输入/输出及副作用：recovery（输入）；canonical_queue_reservation_release_recovery 读取 recovery 并使用字段 backing_completed；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：canonical_queue_reservation_release_recovery 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function bit canonical_queue_reservation_release_recovery(
    rdma_recovery_record recovery
  );
    int unsigned backing_completed;

    if (recovery == null || !recovery.queue_recovery_valid ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.queue_intent != RDMA_QUEUE_RECOVER_CREATE_ROLLBACK ||
        recovery.ambiguous_queue_operation != RDMA_QUEUE_AMBIG_NONE ||
        recovery.ambiguous_ticket != null || recovery.queue_plan == null ||
        recovery.pending_steps.size() != 1 ||
        recovery.pending_steps[0] != RDMA_CTRL_STEP_RESOURCE_RELEASED)
      return 1'b0;
    backing_completed = 0;
    foreach (recovery.completed_steps[i])
      if (recovery.completed_steps[i] == RDMA_CTRL_STEP_BACKING_RELEASED)
        backing_completed++;
    return backing_completed == 1;
  endfunction

  // 功能：borrowed_queue_backing_release_intact 只读检查 borrowed queue backing 及其附加段仍可安全借用，
  //       先验证 backing 自身，再按原顺序验证每个 additional segment。
  // 输入/输出及副作用：backing（输入）；backing_fields_intact（输出，仅在返回 0 时区分 backing 自身字段失败还是附加段失败）；
  //       函数仅读取 ownership、cleanup_complete、mapping、additional_segments 及 mapping.state，
  //       不修改对象、账本或外部资源，
  //       返回 bit 表示整棵 borrowed backing 图是否完整。
  // 失败/边界：backing 为空、ownership 不是 RDMA_OWNERSHIP_BORROWED、cleanup_complete 已置位、
  //       主 mapping 为空或非 RDMA_MAPPING_ACTIVE 时返回 0 且 backing_fields_intact=0；
  //       任一 additional segment 为空、ownership 非 BORROWED、mapping 为空或非 ACTIVE 时返回 0，
  //       且 backing_fields_intact=1；
  //       空 additional_segments 表示没有附加段，按既有释放语义通过检查。
  protected function bit borrowed_queue_backing_release_intact(
    rdma_queue_backing_ref backing,
    output bit backing_fields_intact
  );
    backing_fields_intact = 1'b0;
    if (backing == null ||
        backing.ownership != RDMA_OWNERSHIP_BORROWED ||
        backing.cleanup_complete ||
        backing.mapping == null ||
        backing.mapping.state != RDMA_MAPPING_ACTIVE)
      return 1'b0;
    backing_fields_intact = 1'b1;
    foreach (backing.additional_segments[i]) begin
      if (backing.additional_segments[i] == null ||
          backing.additional_segments[i].ownership !=
            RDMA_OWNERSHIP_BORROWED ||
          backing.additional_segments[i].mapping == null ||
          backing.additional_segments[i].mapping.state !=
            RDMA_MAPPING_ACTIVE)
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：owned_additional_segments_release_complete 只读核对 control-plane
  //       owned queue backing 的全部 additional_segments 都已取得释放完成证明，
  //       让 reservation/local 两类释放计划共享同一段 segment 级校验。
  // 输入/输出及副作用：backing（输入）；函数遍历 backing.additional_segments，
  //       对每个 segment.mapping 调用 query_owned_release_completion，并返回 bit；
  //       函数不写 backing、mapping、账本或资源所有权，也不生成业务错误 status。
  // 失败/边界：backing 为空、ownership 不是 RDMA_OWNERSHIP_CONTROL_PLANE、segment
  //       为空，或任一 query 返回 null/失败 status 或 release_complete 为 0 时返回
  //       0；空 additional_segments 表示没有附加段，按释放证明语义返回 1。
  protected function bit owned_additional_segments_release_complete(
    rdma_queue_backing_ref backing
  );
    rdma_status status;
    bit release_complete;

    if (backing == null ||
        backing.ownership != RDMA_OWNERSHIP_CONTROL_PLANE)
      return 1'b0;
    foreach (backing.additional_segments[i]) begin
      if (backing.additional_segments[i] == null)
        return 1'b0;
      release_complete = 1'b0;
      status = query_owned_release_completion(
        backing.additional_segments[i].mapping,
        release_complete
      );
      if (status == null || !status.ok() || !release_complete)
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：queue_reservation_release_plan_status 校验 authoritative、candidate 与当前对象状态的一致性，并显式处理“queue reservation recovery plan shape changed”；“queue reservation recovery ring authority changed”；“queue reservation recovery backing authority changed”；“queue reservation recovery owned backing is not released”；“queue reservation recovery backing lacks completion proof”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：authoritative（输入）、candidate（输入）；queue_reservation_release_plan_status 读取 authoritative、candidate 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：queue_reservation_release_plan_status 返回 RDMA_SC_INVALID_ARGUMENT；具体拒绝条件包括 “queue reservation recovery plan shape changed”；“queue reservation recovery ring authority changed”；“queue reservation recovery backing authority changed”；“queue reservation recovery owned backing is not released”；“queue reservation recovery backing lacks completion proof”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status queue_reservation_release_plan_status(
    rdma_queue_backing_plan authoritative,
    rdma_queue_backing_plan candidate
  );
    rdma_status status;
    bit release_complete;
    bit backing_fields_intact;

    if (authoritative == null || candidate == null ||
        authoritative.resource_kind != candidate.resource_kind ||
        authoritative.rings.size() != candidate.rings.size() ||
        authoritative.refs.size() != candidate.refs.size() ||
        authoritative.flush_targets.size() != candidate.flush_targets.size() ||
        ((authoritative.context_ref == null) !=
         (candidate.context_ref == null)))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "queue reservation recovery plan shape changed"
      );
    foreach (authoritative.rings[i]) begin
      if (!same_queue_ring_value(authoritative.rings[i], candidate.rings[i]))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue reservation recovery ring authority changed"
        );
    end
    foreach (authoritative.refs[i]) begin
      if (!same_queue_backing_ref_value(authoritative.refs[i],
                                        candidate.refs[i]) ||
          candidate.refs[i] == null)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue reservation recovery backing authority changed"
        );
      if (candidate.refs[i].ownership == RDMA_OWNERSHIP_CONTROL_PLANE) begin
        if (!candidate.refs[i].cleanup_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue reservation recovery owned backing is not released"
          );
        if (!same_owned_queue_backing_ref_authority(authoritative.refs[i],
                                                    candidate.refs[i]))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue reservation recovery backing authority changed"
          );
        status = query_owned_release_completion(candidate.refs[i].mapping,
                                                release_complete);
        if (status == null || !status.ok() || !release_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue reservation recovery backing lacks completion proof"
          );
        if (!owned_additional_segments_release_complete(candidate.refs[i]))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue reservation recovery segment lacks completion proof"
          );
      end
      else if (candidate.refs[i].ownership == RDMA_OWNERSHIP_BORROWED) begin
        if (authoritative.refs[i].cleanup_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue reservation recovery borrowed backing was released"
          );
        if (!borrowed_queue_backing_release_intact(
              candidate.refs[i], backing_fields_intact)) begin
          if (!backing_fields_intact)
            return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "queue reservation recovery borrowed backing was released"
            );
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue reservation recovery borrowed segment was released"
          );
        end
      end
      else
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue reservation recovery backing ownership is invalid"
        );
    end
    if (candidate.context_ref != null &&
        !same_released_queue_context_value(authoritative.context_ref,
                                           candidate.context_ref))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "queue reservation recovery context lacks completion proof"
      );
    foreach (authoritative.flush_targets[i]) begin
      if (authoritative.flush_targets[i] == null ||
          candidate.flush_targets[i] == null ||
          authoritative.flush_targets[i].role !=
            candidate.flush_targets[i].role ||
          authoritative.flush_targets[i].phase !=
            candidate.flush_targets[i].phase ||
          authoritative.flush_targets[i].flush_complete !=
            candidate.flush_targets[i].flush_complete ||
          !same_queue_backing_ref_value(
            authoritative.flush_targets[i].pd_ref,
            candidate.flush_targets[i].pd_ref
          ))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue reservation recovery flush authority changed"
        );
      if (candidate.flush_targets[i].pd_ref.ownership ==
            RDMA_OWNERSHIP_CONTROL_PLANE) begin
        if (!candidate.flush_targets[i].pd_ref.cleanup_complete ||
            !same_owned_queue_backing_ref_authority(
              authoritative.flush_targets[i].pd_ref,
              candidate.flush_targets[i].pd_ref
            ))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue reservation recovery flush release authority changed"
          );
        status = query_owned_release_completion(
          candidate.flush_targets[i].pd_ref.mapping, release_complete
        );
        if (status == null || !status.ok() || !release_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue reservation recovery flush lacks completion proof"
          );
        if (!owned_additional_segments_release_complete(
              candidate.flush_targets[i].pd_ref))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue reservation recovery flush segment lacks completion proof"
          );
      end
      else if (candidate.flush_targets[i].pd_ref.ownership ==
                 RDMA_OWNERSHIP_BORROWED) begin
        if (authoritative.flush_targets[i].pd_ref.cleanup_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue reservation recovery borrowed flush backing was released"
          );
        if (!borrowed_queue_backing_release_intact(
              candidate.flush_targets[i].pd_ref, backing_fields_intact)) begin
          if (!backing_fields_intact)
            return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "queue reservation recovery borrowed flush backing was released"
            );
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue reservation recovery borrowed flush segment was released"
          );
        end
      end
      else
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue reservation recovery flush ownership is invalid"
        );
    end
    return rdma_status::success();
  endfunction

  // 功能：queue_local_release_plan_status 校验 candidate 与当前对象状态的一致性，并显式处理“queue local release plan is missing”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：candidate（输入）；queue_local_release_plan_status 读取 candidate 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：queue_local_release_plan_status 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“queue local release plan is missing”“queue local release backing is missing”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status queue_local_release_plan_status(
    rdma_queue_backing_plan candidate
  );
    rdma_queue_slot_token_contract token;
    rdma_status status;
    bit release_complete;
    bit backing_fields_intact;

    if (candidate == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "queue local release plan is missing"
      );
    foreach (candidate.refs[i]) begin
      if (candidate.refs[i] == null)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue local release backing is missing"
        );
      if (candidate.refs[i].ownership == RDMA_OWNERSHIP_CONTROL_PLANE) begin
        if (!candidate.refs[i].cleanup_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue local owned release backing is incomplete"
          );
        status = query_owned_release_completion(candidate.refs[i].mapping,
                                                release_complete);
        if (status == null || !status.ok() || !release_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue local release backing proof is incomplete"
          );
        if (!owned_additional_segments_release_complete(candidate.refs[i]))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue local release segment proof is incomplete"
          );
      end
      else if (candidate.refs[i].ownership == RDMA_OWNERSHIP_BORROWED) begin
        if (!borrowed_queue_backing_release_intact(
              candidate.refs[i], backing_fields_intact)) begin
          if (!backing_fields_intact)
            return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "queue local borrowed backing was released"
            );
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue local borrowed segment was released"
          );
        end
      end
      else
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue local release backing ownership is invalid"
        );
    end
    if (candidate.context_ref != null) begin
      if (!$cast(token, candidate.context_ref.slot_token) ||
          token.completion_authority == null ||
          !token.completion_authority.complete ||
          !candidate.context_ref.release_complete)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue local release context proof is incomplete"
        );
    end
    foreach (candidate.flush_targets[i]) begin
      if (candidate.flush_targets[i] == null ||
          candidate.flush_targets[i].pd_ref == null)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue local release flush backing is missing"
        );
      if (candidate.flush_targets[i].pd_ref.ownership ==
            RDMA_OWNERSHIP_CONTROL_PLANE) begin
        if (!candidate.flush_targets[i].pd_ref.cleanup_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue local owned flush backing is incomplete"
          );
        status = query_owned_release_completion(
          candidate.flush_targets[i].pd_ref.mapping, release_complete
        );
        if (status == null || !status.ok() || !release_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue local owned flush backing proof is incomplete"
          );
        if (!owned_additional_segments_release_complete(
              candidate.flush_targets[i].pd_ref))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue local owned flush segment proof is incomplete"
          );
      end
      else if (candidate.flush_targets[i].pd_ref.ownership ==
                 RDMA_OWNERSHIP_BORROWED) begin
        if (!borrowed_queue_backing_release_intact(
              candidate.flush_targets[i].pd_ref, backing_fields_intact)) begin
          if (!backing_fields_intact)
            return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "queue local borrowed flush backing was released"
            );
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "queue local borrowed flush segment was released"
          );
        end
      end
      else
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue local release flush ownership is invalid"
        );
    end
    return rdma_status::success();
  endfunction

  // Completion is an adapter-defined opaque fact.  Invoke its virtual query
  // only on an authority-preserving clone, and reject any public value, type,
  // or handle-alias mutation at the hook boundary.
  // 功能：在 rdma_resource_manager 中，query_owned_release_completion 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：mapping（输入）、release_complete（输出）；query_owned_release_completion 读取 mapping、release_complete 并使用字段 release_complete、mapping_type、status、query_type，并写入 release_complete；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：query_owned_release_completion 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  function rdma_status query_owned_release_completion(
    rdma_dma_mapping mapping,
    output bit release_complete
  );
    rdma_dma_mapping completion_query;
    rdma_dma_mapping saved_mapping;
    rdma_dma_mapping saved_query;
    rdma_status status;
    uvm_object_wrapper mapping_type;
    uvm_object_wrapper query_type;

    release_complete = 1'b0;
    if (mapping == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "release completion mapping is null"
      );
    mapping_type = mapping.get_object_type();
    status = project_mapping_value(
      mapping, "release completion input guard", saved_mapping
    );
    if (status == null || !status.ok() || mapping_type == null ||
        !mapping_hook_value_intact(mapping, saved_mapping, mapping_type))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "release completion input guard is invalid"
      );
    status = clone_owned_mapping_value(
      mapping, "release completion query", completion_query
    );
    if (status == null || !status.ok() || completion_query == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "release completion query clone is invalid"
      );
    query_type = completion_query.get_object_type();
    status = project_mapping_value(
      completion_query, "release completion query guard", saved_query
    );
    if (status == null || !status.ok() || query_type == null ||
        query_type != mapping_type ||
        !mapping_hook_value_intact(completion_query, saved_query,
                                   query_type) ||
        !mapping_handles_detached(mapping, completion_query))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "release completion query guard is invalid"
      );
    status = completion_query.release_completion_status(release_complete);
    if (status == null ||
        !mapping_hook_value_intact(mapping, saved_mapping, mapping_type) ||
        !mapping_hook_value_intact(completion_query, saved_query,
                                   query_type) ||
        !mapping_handles_detached(mapping, completion_query)) begin
      release_complete = 1'b0;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "release completion hook changed mapping value, type, or aliases"
      );
    end
    if (!status.ok()) begin
      release_complete = 1'b0;
      return status;
    end
    return rdma_status::success();
  endfunction

  // Recovery-only QP mappings are retained precisely for cases where the
  // normal snapshot/equivalence hooks are unavailable or have rejected the
  // allocation.  Query completion on a guarded concrete clone so the opaque
  // adapter seal remains authoritative without reopening those hooks.
  // 功能：在 rdma_resource_manager 中，query_qp_recovery_release_completion 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：mapping（输入）、release_complete（输出）；query_qp_recovery_release_completion 读取 mapping、release_complete 并使用字段 release_complete、status，并写入 release_complete；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：query_qp_recovery_release_completion 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  protected function rdma_status query_qp_recovery_release_completion(
    rdma_dma_mapping mapping,
    output bit release_complete
  );
    rdma_dma_mapping completion_query;
    rdma_status status;
    bit after_complete;

    release_complete = 1'b0;
    if (mapping == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP recovery completion mapping is null"
      );
    status = clone_recovery_mapping_value(
      mapping, "QP recovery completion query", completion_query
    );
    if (status == null || !status.ok() || completion_query == null)
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP recovery completion query clone returned null"
      ) : status;
    status = completion_query.release_completion_status(after_complete);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP recovery completion query returned null"
      );
    if (!status.ok())
      return status;
    if (!same_mapping_value(mapping, completion_query) ||
        !mapping_handles_detached(mapping, completion_query))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP recovery completion query changed mapping value or aliases"
      );
    release_complete = after_complete;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_backing_ref_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_backing_ref_value 读取 source、copy_label、result 并使用字段 result、result.mapping、status、result.ownership、result.release_complete，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_backing_ref_value 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status project_backing_ref_value(
    rdma_backing_ref source,
    string copy_label,
    output rdma_backing_ref result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_backing_ref"});
    result.mapping = null;
    if (source.ownership == RDMA_OWNERSHIP_CONTROL_PLANE)
      status = clone_owned_mapping_value(
        source.mapping, {copy_label, "_mapping"}, result.mapping
      );
    else
      status = project_mapping_value(
        source.mapping, {copy_label, "_mapping"}, result.mapping
      );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.ownership = source.ownership;
    result.release_complete = source.release_complete;
    status = result.validate();
    if (status == null) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {copy_label, " backing validation returned null"}
      );
    end
    if (!status.ok())
      result = null;
    return status;
  endfunction

  // 功能：在 rdma_resource_manager 中，project_hmc_ref_value 从输入对象提取
  //       受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source、copy_label 为输入，result 为输出；函数读取
  //       source 和 copy_label，并复制 owner、kind、address、size、PBL index、
  //       validity、ownership 与 release_complete；不取得调用方资源所有权。
  // 失败/边界：project_hmc_ref_value 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status project_hmc_ref_value(
    rdma_hmc_ref source,
    string copy_label,
    output rdma_hmc_ref result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_hmc_ref"});
    status = project_function_handle_value(
      source.owner, {copy_label, "_owner"}, result.owner
    );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.object_kind = source.object_kind;
    result.address = source.address;
    result.size = source.size;
    result.first_pbl_index = source.first_pbl_index;
    result.index_valid = source.index_valid;
    result.ownership = source.ownership;
    result.release_complete = source.release_complete;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_bar_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_bar_value 读取 source、copy_label、result 并使用字段 result、result.bar_id、result.base、result.size、result.enabled，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_bar_value 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status project_bar_value(
    rdma_bar_info source,
    string copy_label,
    output rdma_bar_info result
  );
    result = null;
    if (source == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " BAR metadata is null"}
      );
    result = new({copy_label, "_bar"});
    result.bar_id = source.bar_id;
    result.base = source.base;
    result.size = source.size;
    result.enabled = source.enabled;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_pcie_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_pcie_value 读取 source、copy_label、result 并使用字段 result、result.bdf、result.parent_pf_bdf、result.vf_index、result.mse、result.bme、status，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_pcie_value 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status project_pcie_value(
    rdma_pcie_identity source,
    string copy_label,
    output rdma_pcie_identity result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " PCIe identity is null"}
      );
    result = new({copy_label, "_pcie"});
    foreach (result.bar[i])
      result.bar[i] = null;
    result.bdf = source.bdf;
    result.parent_pf_bdf = source.parent_pf_bdf;
    result.vf_index = source.vf_index;
    result.mse = source.mse;
    result.bme = source.bme;
    foreach (source.bar[i]) begin
      status = project_bar_value(
        source.bar[i], $sformatf("%s_bar_%0d", copy_label, i),
        result.bar[i]
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_binding_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_binding_value 读取 source、copy_label、result 并使用字段 result、result.pcie、result.owner_h、status、result.queue_dma、result.queue_caps、result.interrupt_vectors、result.function_uid，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_binding_value 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status project_binding_value(
    rdma_function_binding source,
    string copy_label,
    output rdma_function_binding result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " Function binding is null"}
      );
    result = new({copy_label, "_binding"});
    result.pcie = null;
    result.owner_h = null;
    status = project_pcie_value(source.pcie, {copy_label, "_pcie"},
                                result.pcie);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    // Preserve the protected identity authority across value projection;
    // copying only legacy mirrors leaves the projected binding unusable.
    status = result.configure_identity(source.function_identity_snapshot());
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.queue_dma = source.queue_dma;
    result.queue_caps = source.queue_caps;
    result.interrupt_vectors = source.interrupt_vectors;
    status = project_handle_value(source.owner_h, {copy_label, "_owner"},
                                  result.owner_h);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.function_uid = source.function_uid;
    result.notify_bar_id = source.notify_bar_id;
    result.notify_base = source.notify_base;
    result.notify_size = source.notify_size;
    result.notify_table_sel = source.notify_table_sel;
    result.notify_table_index = source.notify_table_index;
    result.host_id = source.host_id;
    result.pfvf_id = source.pfvf_id;
    result.rdma_vf_id = source.rdma_vf_id;
    result.global_function_id = source.global_function_id;
    result.vsi_id = source.vsi_id;
    result.state = source.state;
    result.generation = source.generation;
    result.notify_valid = source.notify_valid;
    result.notify_ready = source.notify_ready;
    result.dmi_valid = source.dmi_valid;
    result.dmi_ready = source.dmi_ready;
    result.vft_valid = source.vft_valid;
    result.vft_ready = source.vft_ready;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_opcode_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_opcode_value 读取 source、copy_label、result 并使用字段 result、result.profile_name、result.opcode、result.variant，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_opcode_value 先检查 source == null，再返回 rdma_status::success()；拒绝分支不提交部分状态，也不隐式重试。
  protected function rdma_status project_opcode_value(
    rdma_cmq_opcode_key source,
    string copy_label,
    output rdma_cmq_opcode_key result
  );
    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_opcode"});
    result.profile_name = source.profile_name;
    result.opcode = source.opcode;
    result.variant = source.variant;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_status_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_status_value 读取 source、copy_label、result 并使用字段 result、result.category、result.code、result.hardware_code、result.hardware_code_valid、result.source_engine、result.function_uid、result.generation，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_status_value 先检查 source == null，再返回 rdma_status::success()；拒绝分支不提交部分状态，也不隐式重试。
  protected function rdma_status project_status_value(
    rdma_status source,
    string copy_label,
    output rdma_status result
  );
    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_status"});
    result.category = source.category;
    result.code = source.code;
    result.hardware_code = source.hardware_code;
    result.hardware_code_valid = source.hardware_code_valid;
    result.source_engine = source.source_engine;
    result.function_uid = source.function_uid;
    result.generation = source.generation;
    result.resource_id = source.resource_id;
    result.command_id = source.command_id;
    result.wr_id = source.wr_id;
    result.severity = source.severity;
    result.retryable = source.retryable;
    result.message = source.message;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_ticket_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_ticket_value 读取 source、copy_label、result 并使用字段 result、status、result.command_id、result.slot_sequence、result.sq_index、result.sq_wrap、result.absolute_deadline，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_ticket_value 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status project_ticket_value(
    rdma_cmq_ticket source,
    string copy_label,
    output rdma_cmq_ticket result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_ticket"});
    status = project_function_handle_value(
      source.function_h, {copy_label, "_function"}, result.function_h
    );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    status = project_handle_value(source.cmq_h, {copy_label, "_cmq"},
                                  result.cmq_h);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    status = project_opcode_value(source.opcode_key, {copy_label, "_opcode"},
                                  result.opcode_key);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.command_id = source.command_id;
    result.slot_sequence = source.slot_sequence;
    result.sq_index = source.sq_index;
    result.sq_wrap = source.sq_wrap;
    result.absolute_deadline = source.absolute_deadline;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_recovery_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_recovery_value 读取 source、copy_label、result 并使用字段 result、status、result.hardware_presence、result.completed_steps、result.pending_steps、result.queue_recovery_valid、result.queue_intent、result.ambiguous_queue_operation，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_recovery_value 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status project_recovery_value(
    rdma_recovery_record source,
    string copy_label,
    output rdma_recovery_record result
  );
    rdma_backing_ref backing_copy;
    rdma_hmc_ref hmc_copy;
    rdma_status status_copy;
    rdma_status status;
    rdma_cmq_opcode_key opcode_copy;
    rdma_queue_backing_plan plan_copy;
    rdma_qp_recovery_state qp_recovery_copy;

    result = null;
    if (source == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " recovery record is null"}
      );
    result = new({copy_label, "_recovery"});
    status = project_handle_value(source.resource_h,
                                  {copy_label, "_resource"},
                                  result.resource_h);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.hardware_presence = source.hardware_presence;
    result.completed_steps = source.completed_steps;
    result.pending_steps = source.pending_steps;
    result.backing_refs.delete();
    foreach (source.backing_refs[i]) begin
      status = project_backing_ref_value(
        source.backing_refs[i], $sformatf("%s_backing_%0d", copy_label, i),
        backing_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.backing_refs.push_back(backing_copy);
    end
    result.hmc_refs.delete();
    foreach (source.hmc_refs[i]) begin
      status = project_hmc_ref_value(
        source.hmc_refs[i], $sformatf("%s_hmc_%0d", copy_label, i), hmc_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.hmc_refs.push_back(hmc_copy);
    end
    status = project_ticket_value(source.ambiguous_ticket,
                                  {copy_label, "_ticket"},
                                  result.ambiguous_ticket);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    status = project_status_value(source.primary_status,
                                  {copy_label, "_primary"},
                                  result.primary_status);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.rollback_statuses.delete();
    foreach (source.rollback_statuses[i]) begin
      status = project_status_value(
        source.rollback_statuses[i],
        $sformatf("%s_rollback_%0d", copy_label, i), status_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.rollback_statuses.push_back(status_copy);
    end
    result.queue_recovery_valid = source.queue_recovery_valid;
    result.queue_intent = source.queue_intent;
    result.ambiguous_queue_operation = source.ambiguous_queue_operation;
    result.ambiguous_role = source.ambiguous_role;
    status = project_opcode_value(source.queue_create_opcode,
                                  {copy_label, "_queue_create"},
                                  opcode_copy);
    if (!status.ok()) begin result = null; return status; end
    result.queue_create_opcode = opcode_copy;
    status = project_opcode_value(source.queue_delete_opcode,
                                  {copy_label, "_queue_delete"},
                                  opcode_copy);
    if (!status.ok()) begin result = null; return status; end
    result.queue_delete_opcode = opcode_copy;
    status = project_opcode_value(source.queue_query_opcode,
                                  {copy_label, "_queue_query"},
                                  opcode_copy);
    if (!status.ok()) begin result = null; return status; end
    result.queue_query_opcode = opcode_copy;
    status = project_queue_plan_value(source.queue_plan,
                                      {copy_label, "_queue_plan"}, plan_copy);
    if (!status.ok()) begin result = null; return status; end
    result.queue_plan = plan_copy;
    result.qp_recovery_valid = source.qp_recovery_valid;
    status = project_qp_recovery_value(
      source.qp_recovery, {copy_label, "_qp_recovery"}, qp_recovery_copy
    );
    if (!status.ok()) begin result = null; return status; end
    result.qp_recovery = qp_recovery_copy;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_resource_base_fields 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输入）；project_resource_base_fields 读取 source、copy_label、result 并使用字段 status、result.state、result.hmc_fvm_addr、result.hmc_fvm_addr_valid、result.outstanding_ids；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_resource_base_fields 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status project_resource_base_fields(
    rdma_resource source,
    string copy_label,
    rdma_resource result
  );
    rdma_backing_ref backing_copy;
    rdma_hmc_ref hmc_copy;
    rdma_handle dependency_copy;
    rdma_status status;

    status = project_handle_value(source.handle, {copy_label, "_handle"},
                                  result.handle);
    if (!status.ok())
      return status;
    status = project_function_handle_value(
      source.owner, {copy_label, "_owner"}, result.owner
    );
    if (!status.ok())
      return status;
    result.state = source.state;
    result.hmc_fvm_addr = source.hmc_fvm_addr;
    result.hmc_fvm_addr_valid = source.hmc_fvm_addr_valid;
    result.backing_refs.delete();
    foreach (source.backing_refs[i]) begin
      status = project_backing_ref_value(
        source.backing_refs[i], $sformatf("%s_backing_%0d", copy_label, i),
        backing_copy
      );
      if (!status.ok())
        return status;
      result.backing_refs.push_back(backing_copy);
    end
    result.hmc_refs.delete();
    foreach (source.hmc_refs[i]) begin
      status = project_hmc_ref_value(
        source.hmc_refs[i], $sformatf("%s_hmc_%0d", copy_label, i), hmc_copy
      );
      if (!status.ok())
        return status;
      result.hmc_refs.push_back(hmc_copy);
    end
    result.dependencies.delete();
    foreach (source.dependencies[i]) begin
      status = project_handle_value(
        source.dependencies[i],
        $sformatf("%s_dependency_%0d", copy_label, i), dependency_copy
      );
      if (!status.ok())
        return status;
      result.dependencies.push_back(dependency_copy);
    end
    result.outstanding_ids = source.outstanding_ids;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_queue_page_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_queue_page_value 读取 source、copy_label、result 并使用字段 result、result.role、result.mapping_offset、result.logical_page_offset、result.page_iova、status，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_queue_page_value 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status project_queue_page_value(
    rdma_queue_dma_page_ref source,
    string copy_label,
    output rdma_queue_dma_page_ref result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_page"});
    result.role = source.role;
    result.mapping_offset = source.mapping_offset;
    result.logical_page_offset = source.logical_page_offset;
    result.page_iova = source.page_iova;
    status = project_mapping_value(source.mapping,
                                   {copy_label, "_mapping"},
                                   result.mapping);
    if (!status.ok())
      result = null;
    return status;
  endfunction

  // 功能：在 rdma_resource_manager 中，project_queue_ring_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_queue_ring_value 读取 source、copy_label、result 并使用字段 result、result.role、result.entry_size_bytes、result.depth、result.logical_bytes、result.storage_bytes、result.page_count、result.initial_polarity，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_queue_ring_value 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status project_queue_ring_value(
    rdma_queue_ring_layout source,
    string copy_label,
    output rdma_queue_ring_layout result
  );
    rdma_queue_dma_page_ref page_copy;
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_ring"});
    result.role = source.role;
    result.entry_size_bytes = source.entry_size_bytes;
    result.depth = source.depth;
    result.logical_bytes = source.logical_bytes;
    result.storage_bytes = source.storage_bytes;
    result.page_count = source.page_count;
    result.initial_polarity = source.initial_polarity;
    foreach (source.pages[i]) begin
      status = project_queue_page_value(
        source.pages[i], $sformatf("%s_page_%0d", copy_label, i), page_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.pages.push_back(page_copy);
    end
    return rdma_status::success();
  endfunction

  // 功能：project_backing_segment_value 将 queue/QP backing 的一个附加 segment 投影为
  //   detached 对象，复制 source.role、source.ownership、source.mapping_offset、
  //   source.length 和 source.logical_queue_offset，并按 ownership 选择 mapping clone
  //   或值投影，供两类 backing-ref 快照共用。
  // 输入/输出及副作用：source、segment_label、null_error、owned_mapping_label 和
  //   borrowed_mapping_label（输入）；result（输出）。函数读取 source.mapping，写入
  //   新的 result，不取得 source 或 mapping 的业务所有权。
  // 失败/边界：source 为空时按 null_error 返回 RDMA_SC_INVALID_ARGUMENT；映射投影失败
  //   时原样传播 status 并清空 result；函数不额外执行几何、role 或 ownership 校验，
  //   borrowed 的 null mapping 继续遵循 project_mapping_value 的既有语义。
  protected function rdma_status project_backing_segment_value(
    rdma_queue_backing_segment source,
    string segment_label,
    string null_error,
    string owned_mapping_label,
    string borrowed_mapping_label,
    output rdma_queue_backing_segment result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, null_error);
    result = new(segment_label);
    result.role = source.role;
    result.ownership = source.ownership;
    result.mapping_offset = source.mapping_offset;
    result.length = source.length;
    result.logical_queue_offset = source.logical_queue_offset;
    if (result.ownership == RDMA_OWNERSHIP_CONTROL_PLANE)
      status = clone_owned_mapping_value(
        source.mapping, owned_mapping_label, result.mapping
      );
    else
      status = project_mapping_value(
        source.mapping, borrowed_mapping_label, result.mapping
      );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_queue_backing_ref_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_queue_backing_ref_value 读取 source、copy_label、result 并使用字段 result、result.role、result.ownership、result.mapping_offset、result.length、result.logical_queue_offset、result.cleanup_complete、status，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_queue_backing_ref_value 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status project_queue_backing_ref_value(
    rdma_queue_backing_ref source,
    string copy_label,
    output rdma_queue_backing_ref result
  );
    rdma_queue_backing_segment segment_copy;
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_ref"});
    result.role = source.role;
    result.ownership = source.ownership;
    result.mapping_offset = source.mapping_offset;
    result.length = source.length;
    result.logical_queue_offset = source.logical_queue_offset;
    result.cleanup_complete = source.cleanup_complete;
    if (source.ownership == RDMA_OWNERSHIP_CONTROL_PLANE)
      status = clone_owned_mapping_value(source.mapping,
                                         {copy_label, "_owned_mapping"},
                                         result.mapping);
    else
      status = project_mapping_value(source.mapping,
                                     {copy_label, "_borrowed_mapping"},
                                     result.mapping);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    foreach (source.additional_segments[i]) begin
      status = project_backing_segment_value(
        source.additional_segments[i],
        $sformatf("%s_segment_%0d", copy_label, i),
        {copy_label, " additional backing segment is null"},
        $sformatf("%s_segment_%0d_owned_mapping", copy_label, i),
        $sformatf("%s_segment_%0d_borrowed_mapping", copy_label, i),
        segment_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.additional_segments.push_back(segment_copy);
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_queue_slot_token_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_queue_slot_token_value 读取 source、copy_label、result 并使用字段 result、cloned_object，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_queue_slot_token_value 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status project_queue_slot_token_value(
    uvm_object source,
    string copy_label,
    output uvm_object result
  );
    rdma_queue_slot_token_contract source_token;
    rdma_queue_slot_token_contract result_token;
    uvm_object cloned_object;

    result = null;
    if (source == null)
      return rdma_status::success();
    if (!$cast(source_token, source) ||
        source_token.completion_authority == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " slot token contract is invalid"}
      );
    cloned_object = source_token.clone();
    if (cloned_object == null || cloned_object == source ||
        !$cast(result_token, cloned_object) ||
        result_token.completion_authority == null ||
        result_token.completion_authority !==
          source_token.completion_authority)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " slot token clone lost opaque authority"}
      );
    result = result_token;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_queue_context_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_queue_context_value 读取 source、copy_label、result 并使用字段 result、status、result.resource_kind、result.local_id、result.shadow_pointer_base、result.slot_length、result.shadow_view_offset、result.shadow_view_length，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_queue_context_value 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status project_queue_context_value(
    rdma_context_backing_ref source,
    string copy_label,
    output rdma_context_backing_ref result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_context"});
    status = project_function_handle_value(
      source.owner, {copy_label, "_owner"}, result.owner
    );
    if (status.ok())
      status = project_queue_slot_token_value(
        source.slot_token, {copy_label, "_token"}, result.slot_token
      );
    if (status.ok())
      status = project_hmc_ref_value(
        source.hmc_ref, {copy_label, "_hmc"}, result.hmc_ref
      );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.resource_kind = source.resource_kind;
    result.local_id = source.local_id;
    result.shadow_pointer_base = source.shadow_pointer_base;
    result.slot_length = source.slot_length;
    result.shadow_view_offset = source.shadow_view_offset;
    result.shadow_view_length = source.shadow_view_length;
    result.release_complete = source.release_complete;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_queue_flush_target_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_queue_flush_target_value 读取 source、copy_label、result 并使用字段 result、result.role、result.phase、result.flush_complete、status，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_queue_flush_target_value 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status project_queue_flush_target_value(
    rdma_queue_flush_target source,
    string copy_label,
    output rdma_queue_flush_target result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_flush"});
    result.role = source.role;
    result.phase = source.phase;
    result.flush_complete = source.flush_complete;
    status = project_queue_backing_ref_value(
      source.pd_ref, {copy_label, "_pd_ref"}, result.pd_ref
    );
    if (!status.ok())
      result = null;
    return status;
  endfunction

  // 功能：在 rdma_resource_manager 中，project_queue_plan_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_queue_plan_value 读取 source、copy_label、result 并使用字段 result、result.resource_kind、status，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_queue_plan_value 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status project_queue_plan_value(
    rdma_queue_backing_plan source,
    string copy_label,
    output rdma_queue_backing_plan result
  );
    rdma_queue_ring_layout ring_copy;
    rdma_queue_backing_ref ref_copy;
    rdma_queue_flush_target flush_copy;
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_plan"});
    result.resource_kind = source.resource_kind;
    foreach (source.rings[i]) begin
      status = project_queue_ring_value(
        source.rings[i], $sformatf("%s_ring_%0d", copy_label, i), ring_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.rings.push_back(ring_copy);
    end
    foreach (source.refs[i]) begin
      status = project_queue_backing_ref_value(
        source.refs[i], $sformatf("%s_ref_%0d", copy_label, i), ref_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.refs.push_back(ref_copy);
    end
    status = project_queue_context_value(
      source.context_ref, {copy_label, "_context"}, result.context_ref
    );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    foreach (source.flush_targets[i]) begin
      status = project_queue_flush_target_value(
        source.flush_targets[i],
        $sformatf("%s_flush_%0d", copy_label, i), flush_copy
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.flush_targets.push_back(flush_copy);
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_qp_ring_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_qp_ring_value 读取 source、copy_label、result 并使用字段 result、result.role、result.entry_size_bytes、result.depth、result.logical_bytes、result.storage_bytes、result.object_mode，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_qp_ring_value 先检查 source == null，再返回 rdma_status::success()；拒绝分支不提交部分状态，也不隐式重试。
  protected function rdma_status project_qp_ring_value(
    rdma_qp_ring_layout source,
    string copy_label,
    output rdma_qp_ring_layout result
  );
    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_ring"});
    result.role = source.role;
    result.entry_size_bytes = source.entry_size_bytes;
    result.depth = source.depth;
    result.logical_bytes = source.logical_bytes;
    result.storage_bytes = source.storage_bytes;
    result.object_mode = source.object_mode;
    return rdma_status::success();
  endfunction

  // Recovery-only QP references deliberately bypass the normal owned-mapping
  // snapshot/equivalence hooks: those hooks are the operation that failed
  // while the allocation was being validated.  Preserve the concrete clone
  // (and therefore its opaque adapter release token) and require only value,
  // detached-handle, and completion-query authority here.  The reference
  // validator separately enforces the exact Function/QP owner and role.
  // 功能：在 rdma_resource_manager 中，clone_recovery_mapping_value 将 rhs 中 rdma_resource_manager 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；clone_recovery_mapping_value 读取 source、copy_label、result 并使用字段 result、source_type、status、cloned_object、result_type，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：clone_recovery_mapping_value 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status clone_recovery_mapping_value(
    rdma_dma_mapping source,
    string copy_label,
    output rdma_dma_mapping result
  );
    uvm_object cloned_object;
    uvm_object_wrapper source_type;
    uvm_object_wrapper result_type;
    rdma_status status;
    bit source_complete;
    bit result_complete;

    result = null;
    if (source == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " recovery mapping is null"}
      );
    source_type = source.get_object_type();
    if (source_type == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " recovery mapping type is not registered"}
      );
    status = source.release_completion_status(source_complete);
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {copy_label, " recovery completion authority query returned null"}
      ) : status;
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(result, cloned_object) ||
        result == source)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " recovery mapping clone contract failed"}
      );
    result_type = result.get_object_type();
    if (result_type == null || result_type != source_type ||
        !same_mapping_value(source, result) ||
        !mapping_handles_detached(source, result)) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " recovery mapping clone changed value, type, or aliases"}
      );
    end
    status = result.release_completion_status(result_complete);
    if (status == null || !status.ok() || source_complete != result_complete) begin
      result = null;
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {copy_label, " recovery clone completion authority changed"}
      ) : status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " recovery clone completion state changed"}
      ) : status;
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_qp_backing_ref_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_qp_backing_ref_value 读取 source、copy_label、result 并使用字段 result、status、result.role、result.ownership、result.mapping_offset、result.length、result.cleanup_complete、result.recovery_only，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_qp_backing_ref_value 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“QP backing segment is null”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status project_qp_backing_ref_value(
    rdma_qp_backing_ref source,
    string copy_label,
    output rdma_qp_backing_ref result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_ref"});
    if (source.recovery_only)
      status = clone_recovery_mapping_value(
        source.mapping, {copy_label, "_recovery_mapping"}, result.mapping
      );
    else if (source.ownership == RDMA_OWNERSHIP_CONTROL_PLANE)
      status = clone_owned_mapping_value(
        source.mapping, {copy_label, "_owned_mapping"}, result.mapping
      );
    else
      status = project_mapping_value(
        source.mapping, {copy_label, "_borrowed_mapping"}, result.mapping
      );
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.role = source.role;
    result.ownership = source.ownership;
    result.mapping_offset = source.mapping_offset;
    result.length = source.length;
    result.cleanup_complete = source.cleanup_complete;
    result.recovery_only = source.recovery_only;
    result.additional_segments.delete();
    foreach (source.additional_segments[i]) begin
      rdma_queue_backing_segment segment;

      status = project_backing_segment_value(
        source.additional_segments[i],
        {copy_label, "_segment"},
        "QP backing segment is null",
        {copy_label, "_segment_mapping"},
        {copy_label, "_segment_mapping"},
        segment
      );
      if (!status.ok()) begin
        result = null;
        return status;
      end
      result.additional_segments.push_back(segment);
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_qp_plan_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_qp_plan_value 读取 source、copy_label、result 并使用字段 result、result.transport、result.sq_depth、result.rq_depth、result.sq_pd_flush_complete、result.rq_pd_flush_complete、result.cleanup_complete、status，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_qp_plan_value 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status project_qp_plan_value(
    rdma_qp_backing_plan source,
    string copy_label,
    output rdma_qp_backing_plan result
  );
    rdma_qp_backing_ref ref_copy;
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_plan"});
    result.transport = source.transport;
    result.sq_depth = source.sq_depth;
    result.rq_depth = source.rq_depth;
    result.sq_pd_flush_complete = source.sq_pd_flush_complete;
    result.rq_pd_flush_complete = source.rq_pd_flush_complete;
    result.cleanup_complete = source.cleanup_complete;
    status = project_qp_ring_value(source.sq_ring, {copy_label, "_sq"},
                                   result.sq_ring);
    if (status.ok())
      status = project_qp_ring_value(source.rq_ring, {copy_label, "_rq"},
                                     result.rq_ring);
    if (status.ok())
      status = project_qp_backing_ref_value(
        source.sq_ref, {copy_label, "_sq"}, result.sq_ref
      );
    if (status.ok())
      status = project_qp_backing_ref_value(
        source.sq_sgb_ref, {copy_label, "_sq_sgb"}, result.sq_sgb_ref
      );
    if (status.ok())
      status = project_qp_backing_ref_value(
        source.rq_ref, {copy_label, "_rq"}, result.rq_ref
      );
    if (status.ok())
      status = project_qp_backing_ref_value(
        source.sq_pd_ref, {copy_label, "_sq_pd"}, result.sq_pd_ref
      );
    if (status.ok())
      status = project_qp_backing_ref_value(
        source.rq_pd_ref, {copy_label, "_rq_pd"}, result.rq_pd_ref
      );
    if (status.ok())
      status = project_handle_value(source.rq_source_h,
                                    {copy_label, "_rq_source"},
                                    result.rq_source_h);
    if (status.ok()) begin
      result.urc_refs.delete();
      foreach (source.urc_refs[i]) begin
        status = project_qp_backing_ref_value(
          source.urc_refs[i], $sformatf("%s_urc_%0d", copy_label, i),
          ref_copy
        );
        if (!status.ok()) break;
        result.urc_refs.push_back(ref_copy);
      end
    end
    if (status.ok())
      status = project_queue_context_value(
        source.context_ref, {copy_label, "_context"}, result.context_ref
      );
    if (!status.ok())
      result = null;
    return status;
  endfunction

  // 功能：在 rdma_resource_manager 中，project_address_vector_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_address_vector_value 读取 source、copy_label、result 并使用字段 result、result.source_address_index、result.source_vport、result.destination_vport、result.destination_port、result.destination_mac、result.ipv6、result.vlan_enable，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_address_vector_value 先检查 source == null，再返回 rdma_status::success()；拒绝分支不提交部分状态，也不隐式重试。
  protected function rdma_status project_address_vector_value(
    rdma_address_vector source,
    string copy_label,
    output rdma_address_vector result
  );
    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_address_vector"});
    result.source_address_index = source.source_address_index;
    result.source_vport = source.source_vport;
    result.destination_vport = source.destination_vport;
    result.destination_port = source.destination_port;
    result.destination_mac = source.destination_mac;
    foreach (result.destination_ip[i])
      result.destination_ip[i] = source.destination_ip[i];
    result.ipv6 = source.ipv6;
    result.vlan_enable = source.vlan_enable;
    result.cfi = source.cfi;
    result.lag_enable = source.lag_enable;
    result.tunnel_enable = source.tunnel_enable;
    result.forwarding_enable = source.forwarding_enable;
    result.vlan_id = source.vlan_id;
    result.traffic_class = source.traffic_class;
    result.flow_label = source.flow_label;
    result.hop_limit = source.hop_limit;
    result.udp_source_port = source.udp_source_port;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_qpc_behavior_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_qpc_behavior_value 读取 source、copy_label、result 并使用字段 result、result.transport_version、result.migration_enable、result.tx_endian_swap、result.rx_endian_swap、result.read_after_write_fence、result.atomic_after_atomic_fence、priority，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_qpc_behavior_value 先检查 source == null，再返回 rdma_status::success()；拒绝分支不提交部分状态，也不隐式重试。
  protected function rdma_status project_qpc_behavior_value(
    rdma_qpc_behavior source,
    string copy_label,
    output rdma_qpc_behavior result
  );
    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_behavior"});
    result.transport_version = source.transport_version;
    result.migration_enable = source.migration_enable;
    result.tx_endian_swap = source.tx_endian_swap;
    result.rx_endian_swap = source.rx_endian_swap;
    result.read_after_write_fence = source.read_after_write_fence;
    result.atomic_after_atomic_fence = source.atomic_after_atomic_fence;
    result.\priority = source.\priority ;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_qpc_extension_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_qpc_extension_value 读取 source、copy_label、result 并使用字段 result、result_rc、result_rc.remote_qpn、result_rc.send_psn、result_rc.recv_psn、result_rc.retry_count、result_rc.rnr_retry_count、result_ud，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_qpc_extension_value 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status project_qpc_extension_value(
    rdma_qpc_transport_ext source,
    string copy_label,
    output rdma_qpc_transport_ext result
  );
    rdma_qpc_rc_ext source_rc;
    rdma_qpc_rc_ext result_rc;
    rdma_qpc_ud_ext source_ud;
    rdma_qpc_ud_ext result_ud;
    rdma_qpc_urc_ext source_urc;
    rdma_qpc_urc_ext result_urc;

    result = null;
    if (source == null)
      return rdma_status::success();
    if ($cast(source_rc, source)) begin
      result_rc = new({copy_label, "_rc"});
      result_rc.remote_qpn = source_rc.remote_qpn;
      result_rc.send_psn = source_rc.send_psn;
      result_rc.recv_psn = source_rc.recv_psn;
      result_rc.retry_count = source_rc.retry_count;
      result_rc.rnr_retry_count = source_rc.rnr_retry_count;
      result = result_rc;
    end
    else if ($cast(source_ud, source)) begin
      result_ud = new({copy_label, "_ud"});
      result_ud.qkey = source_ud.qkey;
      result_ud.destination_qpn = source_ud.destination_qpn;
      result = result_ud;
    end
    else if ($cast(source_urc, source)) begin
      result_urc = new({copy_label, "_urc"});
      result_urc.remote_qpn = source_urc.remote_qpn;
      result_urc.rbsn = source_urc.rbsn;
      result_urc.dbsn = source_urc.dbsn;
      result_urc.rpsn = source_urc.rpsn;
      result_urc.dpsn = source_urc.dpsn;
      if (source_urc.queues == null)
        result_urc.queues = null;
      else begin
        result_urc.queues = new({copy_label, "_urc_queues"});
        result_urc.queues.rsq_backing = source_urc.queues.rsq_backing;
        result_urc.queues.rdsq_backing = source_urc.queues.rdsq_backing;
        result_urc.queues.dsq_backing = source_urc.queues.dsq_backing;
        result_urc.queues.rsq_depth = source_urc.queues.rsq_depth;
        result_urc.queues.rdsq_depth = source_urc.queues.rdsq_depth;
        result_urc.queues.rdsq_fetch_count =
          source_urc.queues.rdsq_fetch_count;
        result_urc.queues.dsq_fetch_count =
          source_urc.queues.dsq_fetch_count;
        result_urc.queues.rq_sequence_threshold_entries =
          source_urc.queues.rq_sequence_threshold_entries;
        result_urc.queues.sq_completion_threshold_entries =
          source_urc.queues.sq_completion_threshold_entries;
      end
      result = result_urc;
    end
    else
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " QPC transport extension is incompatible"}
      );
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_qpc_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_qpc_value 读取 source、copy_label、result 并使用字段 result、status、result.transport、result.state、result.host_id、result.vf_id、result.stat_index、result.pkey，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_qpc_value 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status project_qpc_value(
    rdma_qpc_model source,
    string copy_label,
    output rdma_qpc_model result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_qpc"});
    status = project_handle_value(source.qp_h, {copy_label, "_qp"},
                                  result.qp_h);
    if (status.ok())
      status = project_handle_value(source.pd_h, {copy_label, "_pd"},
                                    result.pd_h);
    if (status.ok())
      status = project_handle_value(source.send_cq_h,
                                    {copy_label, "_send_cq"},
                                    result.send_cq_h);
    if (status.ok())
      status = project_handle_value(source.recv_cq_h,
                                    {copy_label, "_recv_cq"},
                                    result.recv_cq_h);
    if (status.ok())
      status = project_handle_value(source.srq_h, {copy_label, "_srq"},
                                    result.srq_h);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    result.transport = source.transport;
    result.state = source.state;
    result.host_id = source.host_id;
    result.vf_id = source.vf_id;
    result.stat_index = source.stat_index;
    result.pkey = source.pkey;
    result.qp_sequence = source.qp_sequence;
    result.access = source.access;
    result.path_mtu_bytes = source.path_mtu_bytes;
    result.sq_depth = source.sq_depth;
    result.rq_depth = source.rq_depth;
    result.sq_backing = source.sq_backing;
    result.rq_backing = source.rq_backing;
    result.context_backing = source.context_backing;
    result.sq_mode = source.sq_mode;
    result.rq_mode = source.rq_mode;
    result.signature_enable = source.signature_enable;
    result.tx_flow_control = source.tx_flow_control;
    result.rx_flow_control = source.rx_flow_control;
    status = project_address_vector_value(
      source.address_vector, {copy_label, "_av"}, result.address_vector
    );
    if (status.ok())
      status = project_qpc_behavior_value(
        source.behavior, {copy_label, "_behavior"}, result.behavior
      );
    if (status.ok())
      status = project_qpc_extension_value(
        source.transport_ext, {copy_label, "_extension"},
        result.transport_ext
      );
    if (!status.ok())
      result = null;
    return status;
  endfunction

  // 功能：在 rdma_resource_manager 中由 same_qp_backing_ref_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_qp_backing_ref_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_qp_backing_ref_value(
    rdma_qp_backing_ref lhs,
    rdma_qp_backing_ref rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.role != rhs.role || lhs.ownership != rhs.ownership ||
        lhs.recovery_only != rhs.recovery_only ||
        lhs.mapping_offset != rhs.mapping_offset || lhs.length != rhs.length ||
        lhs.cleanup_complete != rhs.cleanup_complete ||
        lhs.additional_segments.size() != rhs.additional_segments.size())
      return 1'b0;
    foreach (lhs.additional_segments[i]) begin
      if (!same_backing_segment_value(lhs.additional_segments[i],
                                      rhs.additional_segments[i]))
        return 1'b0;
    end
    if (lhs.recovery_only)
      return same_recovery_mapping_value(lhs.mapping, rhs.mapping);
    if (lhs.ownership == RDMA_OWNERSHIP_CONTROL_PLANE)
      return same_mapping_value(lhs.mapping, rhs.mapping) &&
             same_owned_mapping_authority(lhs.mapping, rhs.mapping);
    return same_mapping_value(lhs.mapping, rhs.mapping);
  endfunction

  // 功能：在 rdma_resource_manager 中由 same_qp_ring_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_qp_ring_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_qp_ring_value(
    rdma_qp_ring_layout lhs,
    rdma_qp_ring_layout rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.role == rhs.role &&
           lhs.entry_size_bytes == rhs.entry_size_bytes &&
           lhs.depth == rhs.depth && lhs.logical_bytes == rhs.logical_bytes &&
           lhs.storage_bytes == rhs.storage_bytes &&
           lhs.object_mode == rhs.object_mode;
  endfunction

  // 功能：在 rdma_resource_manager 中复用 context authority 值比较，并由 caller
  //       单独比较 lhs/rhs 的 release_complete，判断两份 context backing 快照是否等价。
  // 输入/输出及副作用：lhs、rhs（输入）；对象、slot token 和 HMC reference 只读；
  //       返回 bit，不更新 runtime、账本或外部 adapter。
  // 失败/边界：两者同为空按值相等通过；单侧为空、token cast/authority/HMC 或共同
  //       字段不一致，或两侧 release_complete 不同，均返回 0，不抛出未处理异常。
  protected function bit same_context_value(
    rdma_context_backing_ref lhs,
    rdma_context_backing_ref rhs
  );
    if (!same_context_authority_value(lhs, rhs))
      return 1'b0;
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.release_complete == rhs.release_complete;
  endfunction

  // 功能：在 rdma_resource_manager 中由 same_qp_plan_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_qp_plan_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_qp_plan_value(
    rdma_qp_backing_plan lhs,
    rdma_qp_backing_plan rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.transport != rhs.transport || lhs.sq_depth != rhs.sq_depth ||
        lhs.rq_depth != rhs.rq_depth ||
        lhs.sq_pd_flush_complete != rhs.sq_pd_flush_complete ||
        lhs.rq_pd_flush_complete != rhs.rq_pd_flush_complete ||
        lhs.cleanup_complete != rhs.cleanup_complete ||
        !same_qp_ring_value(lhs.sq_ring, rhs.sq_ring) ||
        !same_qp_ring_value(lhs.rq_ring, rhs.rq_ring) ||
        !same_qp_backing_ref_value(lhs.sq_ref, rhs.sq_ref) ||
        !same_qp_backing_ref_value(lhs.sq_sgb_ref, rhs.sq_sgb_ref) ||
        !same_qp_backing_ref_value(lhs.rq_ref, rhs.rq_ref) ||
        !same_qp_backing_ref_value(lhs.sq_pd_ref, rhs.sq_pd_ref) ||
        !same_qp_backing_ref_value(lhs.rq_pd_ref, rhs.rq_pd_ref) ||
        !same_handle_instance(lhs.rq_source_h, rhs.rq_source_h) ||
        lhs.urc_refs.size() != rhs.urc_refs.size() ||
        !same_context_value(lhs.context_ref, rhs.context_ref))
      return 1'b0;
    foreach (lhs.urc_refs[i])
      if (!same_qp_backing_ref_value(lhs.urc_refs[i], rhs.urc_refs[i]))
        return 1'b0;
    return 1'b1;
  endfunction

  // 功能：在 rdma_resource_manager 中由 same_address_vector_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_address_vector_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_address_vector_value(
    rdma_address_vector lhs,
    rdma_address_vector rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.source_address_index != rhs.source_address_index ||
        lhs.source_vport != rhs.source_vport ||
        lhs.destination_vport != rhs.destination_vport ||
        lhs.destination_port != rhs.destination_port ||
        lhs.destination_mac != rhs.destination_mac || lhs.ipv6 != rhs.ipv6 ||
        lhs.vlan_enable != rhs.vlan_enable || lhs.cfi != rhs.cfi ||
        lhs.lag_enable != rhs.lag_enable ||
        lhs.tunnel_enable != rhs.tunnel_enable ||
        lhs.forwarding_enable != rhs.forwarding_enable ||
        lhs.vlan_id != rhs.vlan_id ||
        lhs.traffic_class != rhs.traffic_class ||
        lhs.flow_label != rhs.flow_label || lhs.hop_limit != rhs.hop_limit ||
        lhs.udp_source_port != rhs.udp_source_port)
      return 1'b0;
    foreach (lhs.destination_ip[i])
      if (lhs.destination_ip[i] != rhs.destination_ip[i])
        return 1'b0;
    return 1'b1;
  endfunction

  // 功能：在 rdma_resource_manager 中由 same_qpc_behavior_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_qpc_behavior_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_qpc_behavior_value(
    rdma_qpc_behavior lhs,
    rdma_qpc_behavior rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.transport_version == rhs.transport_version &&
           lhs.migration_enable == rhs.migration_enable &&
           lhs.tx_endian_swap == rhs.tx_endian_swap &&
           lhs.rx_endian_swap == rhs.rx_endian_swap &&
           lhs.read_after_write_fence == rhs.read_after_write_fence &&
           lhs.atomic_after_atomic_fence == rhs.atomic_after_atomic_fence &&
           lhs.\priority == rhs.\priority ;
  endfunction

  // 功能：在 rdma_resource_manager 中由 same_qpc_extension_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_qpc_extension_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_qpc_extension_value(
    rdma_qpc_transport_ext lhs,
    rdma_qpc_transport_ext rhs
  );
    rdma_qpc_rc_ext lhs_rc;
    rdma_qpc_rc_ext rhs_rc;
    rdma_qpc_ud_ext lhs_ud;
    rdma_qpc_ud_ext rhs_ud;
    rdma_qpc_urc_ext lhs_urc;
    rdma_qpc_urc_ext rhs_urc;

    if (lhs == null || rhs == null)
      return lhs == rhs;
    if ($cast(lhs_rc, lhs) && $cast(rhs_rc, rhs))
      return lhs_rc.remote_qpn == rhs_rc.remote_qpn &&
             lhs_rc.send_psn == rhs_rc.send_psn &&
             lhs_rc.recv_psn == rhs_rc.recv_psn &&
             lhs_rc.retry_count == rhs_rc.retry_count &&
             lhs_rc.rnr_retry_count == rhs_rc.rnr_retry_count;
    if ($cast(lhs_ud, lhs) && $cast(rhs_ud, rhs))
      return lhs_ud.qkey == rhs_ud.qkey &&
             lhs_ud.destination_qpn == rhs_ud.destination_qpn;
    if ($cast(lhs_urc, lhs) && $cast(rhs_urc, rhs)) begin
      if (lhs_urc.remote_qpn != rhs_urc.remote_qpn ||
          lhs_urc.rbsn != rhs_urc.rbsn || lhs_urc.dbsn != rhs_urc.dbsn ||
          lhs_urc.rpsn != rhs_urc.rpsn || lhs_urc.dpsn != rhs_urc.dpsn ||
          lhs_urc.queues == null || rhs_urc.queues == null)
        return 1'b0;
      return lhs_urc.queues.rsq_backing.value ==
               rhs_urc.queues.rsq_backing.value &&
             lhs_urc.queues.rdsq_backing.value ==
               rhs_urc.queues.rdsq_backing.value &&
             lhs_urc.queues.dsq_backing.value ==
               rhs_urc.queues.dsq_backing.value &&
             lhs_urc.queues.rsq_depth == rhs_urc.queues.rsq_depth &&
             lhs_urc.queues.rdsq_depth == rhs_urc.queues.rdsq_depth &&
             lhs_urc.queues.rdsq_fetch_count ==
               rhs_urc.queues.rdsq_fetch_count &&
             lhs_urc.queues.dsq_fetch_count ==
               rhs_urc.queues.dsq_fetch_count &&
             lhs_urc.queues.rq_sequence_threshold_entries ==
               rhs_urc.queues.rq_sequence_threshold_entries &&
             lhs_urc.queues.sq_completion_threshold_entries ==
               rhs_urc.queues.sq_completion_threshold_entries;
    end
    return 1'b0;
  endfunction

  // 功能：在 rdma_resource_manager 中由 same_qpc_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_qpc_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_qpc_value(
    rdma_qpc_model lhs,
    rdma_qpc_model rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return same_handle_instance(lhs.qp_h, rhs.qp_h) &&
           same_handle_instance(lhs.pd_h, rhs.pd_h) &&
           same_handle_instance(lhs.send_cq_h, rhs.send_cq_h) &&
           same_handle_instance(lhs.recv_cq_h, rhs.recv_cq_h) &&
           same_handle_instance(lhs.srq_h, rhs.srq_h) &&
           lhs.transport == rhs.transport && lhs.state == rhs.state &&
           lhs.host_id == rhs.host_id && lhs.vf_id == rhs.vf_id &&
           lhs.stat_index == rhs.stat_index && lhs.pkey == rhs.pkey &&
           lhs.qp_sequence == rhs.qp_sequence && lhs.access == rhs.access &&
           lhs.path_mtu_bytes == rhs.path_mtu_bytes &&
           lhs.sq_depth == rhs.sq_depth && lhs.rq_depth == rhs.rq_depth &&
           lhs.sq_backing.value == rhs.sq_backing.value &&
           lhs.rq_backing.value == rhs.rq_backing.value &&
           lhs.context_backing.value == rhs.context_backing.value &&
           lhs.sq_mode == rhs.sq_mode && lhs.rq_mode == rhs.rq_mode &&
           lhs.signature_enable == rhs.signature_enable &&
           lhs.tx_flow_control == rhs.tx_flow_control &&
           lhs.rx_flow_control == rhs.rx_flow_control &&
           same_address_vector_value(lhs.address_vector,
                                     rhs.address_vector) &&
           same_qpc_behavior_value(lhs.behavior, rhs.behavior) &&
           same_qpc_extension_value(lhs.transport_ext, rhs.transport_ext);
  endfunction

  // 功能：在 rdma_resource_manager 中由 same_qp_reconciliation_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_qp_reconciliation_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_qp_reconciliation_value(
    rdma_qp lhs,
    rdma_qp rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return same_handle_instance(lhs.handle, rhs.handle) &&
           same_handle_instance(lhs.owner, rhs.owner) &&
           lhs.state == rhs.state &&
           lhs.backing_refs.size() == rhs.backing_refs.size() &&
           lhs.hmc_refs.size() == rhs.hmc_refs.size() &&
           same_dependency_topology(lhs, rhs) &&
           same_outstanding_ids(lhs, rhs) &&
           lhs.hmc_fvm_addr == rhs.hmc_fvm_addr &&
           lhs.hmc_fvm_addr_valid == rhs.hmc_fvm_addr_valid &&
           lhs.local_qp_id == rhs.local_qp_id &&
           lhs.global_qp_id == rhs.global_qp_id &&
           lhs.transport == rhs.transport && lhs.qp_state == rhs.qp_state &&
           lhs.sq_depth == rhs.sq_depth && lhs.rq_depth == rhs.rq_depth &&
           lhs.sq_producer_index == rhs.sq_producer_index &&
           lhs.sq_consumer_index == rhs.sq_consumer_index &&
           lhs.sq_wrap == rhs.sq_wrap &&
           lhs.sq_consumer_wrap == rhs.sq_consumer_wrap &&
           lhs.rq_producer_index == rhs.rq_producer_index &&
           lhs.rq_consumer_index == rhs.rq_consumer_index &&
           lhs.rq_wrap == rhs.rq_wrap &&
           lhs.rq_consumer_wrap == rhs.rq_consumer_wrap &&
           lhs.sq_iova.value == rhs.sq_iova.value &&
           lhs.rq_iova.value == rhs.rq_iova.value &&
           same_handle_instance(lhs.pd_h, rhs.pd_h) &&
           same_handle_instance(lhs.send_cq_h, rhs.send_cq_h) &&
           same_handle_instance(lhs.recv_cq_h, rhs.recv_cq_h) &&
           same_handle_instance(lhs.srq_h, rhs.srq_h) &&
           same_qp_plan_value(lhs.qp_plan, rhs.qp_plan) &&
           same_qpc_value(lhs.programmed_qpc, rhs.programmed_qpc);
  endfunction

  // 功能：在 rdma_resource_manager 中，project_qp_recovery_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_qp_recovery_value 读取 source、copy_label、result 并使用字段 result、result.intent、result.ambiguous_operation、result.ambiguous_role、result.role_complete、result.has_pending_hardware_step、result.query_mapping_recovery_only、result.query_presence_known，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_qp_recovery_value 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status project_qp_recovery_value(
    rdma_qp_recovery_state source,
    string copy_label,
    output rdma_qp_recovery_state result
  );
    rdma_status status;

    result = null;
    if (source == null)
      return rdma_status::success();
    result = new({copy_label, "_qp_recovery"});
    result.intent = source.intent;
    result.ambiguous_operation = source.ambiguous_operation;
    result.ambiguous_role = source.ambiguous_role;
    result.role_complete = source.role_complete;
    result.has_pending_hardware_step = source.has_pending_hardware_step;
    result.query_mapping_recovery_only = source.query_mapping_recovery_only;
    result.query_presence_known = source.query_presence_known;
    result.query_presence = source.query_presence;
    result.error_modify_complete = source.error_modify_complete;
    result.delete_complete = source.delete_complete;
    status = project_qpc_value(source.prior_qpc, {copy_label, "_prior"},
                               result.prior_qpc);
    if (status.ok())
      status = project_qpc_value(source.candidate_qpc,
                                 {copy_label, "_candidate"},
                                 result.candidate_qpc);
    if (status.ok())
      status = project_qp_plan_value(source.qp_plan, {copy_label, "_plan"},
                                     result.qp_plan);
    if (status.ok())
      status = project_queue_context_value(
        source.context_ref, {copy_label, "_context"}, result.context_ref
      );
    if (status.ok() && source.staging_mapping != null)
      status = clone_owned_mapping_value(
        source.staging_mapping, {copy_label, "_staging"},
        result.staging_mapping
      );
    if (status.ok() && source.query_mapping != null)
      status = source.query_mapping_recovery_only ?
        clone_recovery_mapping_value(
          source.query_mapping, {copy_label, "_query_recovery"},
          result.query_mapping
        ) :
        clone_owned_mapping_value(
          source.query_mapping, {copy_label, "_query"}, result.query_mapping
        );
    if (status.ok())
      status = project_opcode_value(source.create_opcode,
                                    {copy_label, "_create"},
                                    result.create_opcode);
    if (status.ok())
      status = project_opcode_value(source.modify_opcode,
                                    {copy_label, "_modify"},
                                    result.modify_opcode);
    if (status.ok())
      status = project_opcode_value(source.delete_opcode,
                                    {copy_label, "_delete"},
                                    result.delete_opcode);
    if (status.ok())
      status = project_opcode_value(source.query_opcode,
                                    {copy_label, "_query_opcode"},
                                    result.query_opcode);
    if (status.ok())
      status = project_opcode_value(source.occ_opcode,
                                    {copy_label, "_occ_opcode"},
                                    result.occ_opcode);
    if (status.ok())
      status = project_ticket_value(source.ambiguous_ticket,
                                    {copy_label, "_ticket"},
                                    result.ambiguous_ticket);
    if (!status.ok())
      result = null;
    return status;
  endfunction

  // 功能：在 rdma_resource_manager 中，project_queue_fields 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、result（输入）、copy_label（输入）；project_queue_fields 读取 source、result、copy_label 并使用字段 result.depth、result.producer_index、result.consumer_index、result.producer_wrap、result.consumer_wrap、result.queue_iova、status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_queue_fields 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status project_queue_fields(
    rdma_queue_resource source,
    rdma_queue_resource result,
    string copy_label
  );
    rdma_status status;

    result.depth = source.depth;
    result.producer_index = source.producer_index;
    result.consumer_index = source.consumer_index;
    result.producer_wrap = source.producer_wrap;
    result.consumer_wrap = source.consumer_wrap;
    result.queue_iova = source.queue_iova;
    status = project_queue_plan_value(source.queue_plan,
                                      {copy_label, "_queue_plan"},
                                      result.queue_plan);
    return status;
  endfunction

  // 功能：在 rdma_resource_manager 中，project_resource_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_resource_value 读取 source、copy_label、result 并使用字段 result、result_function、result_function.binding、result_pd、result_mr、result_cq、result_qp、result_srq，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_resource_value 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status project_resource_value(
    rdma_resource source,
    string copy_label,
    output rdma_resource result
  );
    rdma_function source_function;
    rdma_function result_function;
    rdma_pd source_pd;
    rdma_pd result_pd;
    rdma_mr source_mr;
    rdma_mr result_mr;
    rdma_cq source_cq;
    rdma_cq result_cq;
    uvm_object cloned_object;
    rdma_cqc_model cloned_cqc;
    rdma_qp source_qp;
    rdma_qp result_qp;
    rdma_srq source_srq;
    rdma_srq result_srq;
    rdma_cmq source_cmq;
    rdma_cmq result_cmq;
    rdma_ceq source_ceq;
    rdma_ceq result_ceq;
    rdma_aeq source_aeq;
    rdma_aeq result_aeq;
    rdma_status status;

    result = null;
    if (source == null || source.handle == null ||
        !valid_kind(source.handle.kind))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " resource carrier is structurally incompatible"}
      );

    case (source.handle.kind)
      RDMA_RESOURCE_FUNCTION: begin
        if (!$cast(source_function, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " Function carrier does not match handle kind"}
          );
        result_function = new({copy_label, "_function"});
        result_function.binding = null;
        result = result_function;
      end
      RDMA_RESOURCE_PD: begin
        if (!$cast(source_pd, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " PD carrier does not match handle kind"}
          );
        result_pd = new({copy_label, "_pd"});
        result = result_pd;
      end
      RDMA_RESOURCE_MR: begin
        if (!$cast(source_mr, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " MR carrier does not match handle kind"}
          );
        result_mr = new({copy_label, "_mr"});
        result = result_mr;
      end
      RDMA_RESOURCE_CQ: begin
        if (!$cast(source_cq, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " CQ carrier does not match handle kind"}
          );
        result_cq = new({copy_label, "_cq"});
        result = result_cq;
      end
      RDMA_RESOURCE_QP: begin
        if (!$cast(source_qp, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " QP carrier does not match handle kind"}
          );
        result_qp = new({copy_label, "_qp"});
        result = result_qp;
      end
      RDMA_RESOURCE_SRQ: begin
        if (!$cast(source_srq, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " SRQ carrier does not match handle kind"}
          );
        result_srq = new({copy_label, "_srq"});
        result = result_srq;
      end
      RDMA_RESOURCE_CMQ: begin
        if (!$cast(source_cmq, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " CMQ carrier does not match handle kind"}
          );
        result_cmq = new({copy_label, "_cmq"});
        result = result_cmq;
      end
      RDMA_RESOURCE_CEQ: begin
        if (!$cast(source_ceq, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " CEQ carrier does not match handle kind"}
          );
        result_ceq = new({copy_label, "_ceq"});
        result = result_ceq;
      end
      RDMA_RESOURCE_AEQ: begin
        if (!$cast(source_aeq, source))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            {copy_label, " AEQ carrier does not match handle kind"}
          );
        result_aeq = new({copy_label, "_aeq"});
        result = result_aeq;
      end
      default:
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          {copy_label, " resource kind is invalid"}
        );
    endcase

    status = project_resource_base_fields(source, copy_label, result);
    if (!status.ok()) begin
      result = null;
      return status;
    end

    case (source.handle.kind)
      RDMA_RESOURCE_FUNCTION: begin
        result_function.local_function_id = source_function.local_function_id;
        result_function.global_function_id =
          source_function.global_function_id;
        result_function.rdma_vf_id = source_function.rdma_vf_id;
        result_function.vsi_id = source_function.vsi_id;
        result_function.pfvf_id = source_function.pfvf_id;
        status = project_binding_value(
          source_function.binding, {copy_label, "_binding"},
          result_function.binding
        );
      end
      RDMA_RESOURCE_PD: begin
        result_pd.local_pd_id = source_pd.local_pd_id;
        result_pd.global_pd_id = source_pd.global_pd_id;
      end
      RDMA_RESOURCE_MR: begin
        result_mr.local_mr_id = source_mr.local_mr_id;
        result_mr.global_mr_id = source_mr.global_mr_id;
        status = project_handle_value(
          source_mr.pd_h, {copy_label, "_pd"}, result_mr.pd_h
        );
        result_mr.iova = source_mr.iova;
        result_mr.length = source_mr.length;
        result_mr.lkey = source_mr.lkey;
        result_mr.rkey = source_mr.rkey;
        result_mr.access = source_mr.access;
        result_mr.mr_serial = source_mr.mr_serial;
      end
      RDMA_RESOURCE_CQ: begin
        status = project_queue_fields(source_cq, result_cq, copy_label);
        result_cq.local_cq_id = source_cq.local_cq_id;
        result_cq.global_cq_id = source_cq.global_cq_id;
        result_cq.cqe_size_bytes = source_cq.cqe_size_bytes;
        if (status.ok())
          status = project_handle_value(
            source_cq.ceq_h, {copy_label, "_ceq"}, result_cq.ceq_h
          );
        if (status.ok() && source_cq.programmed_cqc != null) begin
          cloned_object = source_cq.programmed_cqc.clone();
          if (cloned_object == null || !$cast(cloned_cqc, cloned_object) ||
              cloned_cqc == source_cq.programmed_cqc) begin
            status = rdma_status::make(
              RDMA_SC_INVALID_STATE,
              {copy_label, " programmed CQC clone failed"}
            );
          end
          else begin
            result_cq.programmed_cqc = cloned_cqc;
          end
        end
      end
      RDMA_RESOURCE_QP: begin
        result_qp.local_qp_id = source_qp.local_qp_id;
        result_qp.global_qp_id = source_qp.global_qp_id;
        result_qp.transport = source_qp.transport;
        result_qp.qp_state = source_qp.qp_state;
        result_qp.sq_depth = source_qp.sq_depth;
        result_qp.rq_depth = source_qp.rq_depth;
        result_qp.sq_producer_index = source_qp.sq_producer_index;
        result_qp.sq_consumer_index = source_qp.sq_consumer_index;
        result_qp.sq_wrap = source_qp.sq_wrap;
        result_qp.sq_consumer_wrap = source_qp.sq_consumer_wrap;
        result_qp.rq_producer_index = source_qp.rq_producer_index;
        result_qp.rq_consumer_index = source_qp.rq_consumer_index;
        result_qp.rq_wrap = source_qp.rq_wrap;
        result_qp.rq_consumer_wrap = source_qp.rq_consumer_wrap;
        result_qp.sq_iova = source_qp.sq_iova;
        result_qp.rq_iova = source_qp.rq_iova;
        status = project_handle_value(
          source_qp.pd_h, {copy_label, "_pd"}, result_qp.pd_h
        );
        if (status.ok())
          status = project_handle_value(
            source_qp.send_cq_h, {copy_label, "_send_cq"},
            result_qp.send_cq_h
          );
        if (status.ok())
          status = project_handle_value(
            source_qp.recv_cq_h, {copy_label, "_recv_cq"},
            result_qp.recv_cq_h
          );
        if (status.ok())
          status = project_handle_value(
            source_qp.srq_h, {copy_label, "_srq"}, result_qp.srq_h
          );
        if (status.ok())
          status = project_qp_plan_value(
            source_qp.qp_plan, {copy_label, "_qp_plan"}, result_qp.qp_plan
          );
        if (status.ok())
          status = project_qpc_value(
            source_qp.programmed_qpc, {copy_label, "_programmed_qpc"},
            result_qp.programmed_qpc
          );
      end
      RDMA_RESOURCE_SRQ: begin
        status = project_queue_fields(source_srq, result_srq, copy_label);
        result_srq.local_srq_id = source_srq.local_srq_id;
        result_srq.global_srq_id = source_srq.global_srq_id;
        result_srq.max_sge = source_srq.max_sge;
        result_srq.limit_threshold = source_srq.limit_threshold;
        if (status.ok())
          status = project_handle_value(
            source_srq.pd_h, {copy_label, "_pd"}, result_srq.pd_h
          );
      end
      RDMA_RESOURCE_CMQ: begin
        status = project_queue_fields(source_cmq, result_cmq, copy_label);
        result_cmq.local_cmq_id = source_cmq.local_cmq_id;
        result_cmq.global_cmq_id = source_cmq.global_cmq_id;
        result_cmq.completion_producer_index =
          source_cmq.completion_producer_index;
        result_cmq.completion_consumer_index =
          source_cmq.completion_consumer_index;
        result_cmq.completion_wrap = source_cmq.completion_wrap;
        result_cmq.completion_consumer_wrap =
          source_cmq.completion_consumer_wrap;
        result_cmq.completion_iova = source_cmq.completion_iova;
      end
      RDMA_RESOURCE_CEQ: begin
        status = project_queue_fields(source_ceq, result_ceq, copy_label);
        result_ceq.local_ceq_id = source_ceq.local_ceq_id;
        result_ceq.global_ceq_id = source_ceq.global_ceq_id;
        result_ceq.function_local_vector = source_ceq.function_local_vector;
        result_ceq.hardware_vector = source_ceq.hardware_vector;
        result_ceq.msix_table_index = source_ceq.msix_table_index;
      end
      RDMA_RESOURCE_AEQ: begin
        status = project_queue_fields(source_aeq, result_aeq, copy_label);
        result_aeq.local_aeq_id = source_aeq.local_aeq_id;
        result_aeq.global_aeq_id = source_aeq.global_aeq_id;
        result_aeq.function_local_vector = source_aeq.function_local_vector;
        result_aeq.hardware_vector = source_aeq.hardware_vector;
        result_aeq.msix_table_index = source_aeq.msix_table_index;
      end
      default: begin
        status = rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          {copy_label, " resource kind changed during projection"}
        );
      end
    endcase

    if (status == null || !status.ok()) begin
      result = null;
      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          {copy_label, " projection returned null status"}
        );
      return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：registry_schema_status 先为 registry 的每一项建立 detached schema 投影，再
  //   在单一 mutation guard 窗口内一次性提交，供 quiesce、teardown 和 leak audit
  //   复用一致的快照校验边界。
  // 输入/输出及副作用：operation（输入）决定投影诊断前缀；函数只在全部投影成功、
  //   publication_epoch 未改变且原始 registry 引用仍保持一致时替换 registry 条目，
  //   返回 rdma_status，不取得外部资源或 adapter 所有权。
  // 失败/边界：任一 clone/factory 投影失败、mutation_guard 忙、epoch 变化或 registry
  //   条目在 detached 窗口被替换时返回明确错误，并保证本次调用不写入任何已投影条目；
  //   guard 只包围最终写回，不在外部 callback 期间持有，避免反向重入死锁。
  protected function rdma_status registry_schema_status(string operation);
    rdma_resource projected_registry[string];
    rdma_resource source_registry[string];
    rdma_resource projected;
    rdma_status status;
    longint unsigned epoch_snapshot;

    epoch_snapshot = publication_epoch;
    foreach (registry[key]) begin
      source_registry[key] = registry[key];
      status = project_resource_value(
        registry[key], {operation, "_registry_entry"}, projected
      );
      if (!status.ok())
        return status;
      if (projected == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          {operation, " registry projection returned null"}
        );
      projected_registry[key] = projected;
    end
    if (mutation_guard == null || !mutation_guard.try_get(1))
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        {operation, " registry schema commit window is busy"}
      );
    if (publication_epoch != epoch_snapshot) begin
      mutation_guard.put(1);
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " registry schema epoch changed during projection"}
      );
    end
    foreach (source_registry[key]) begin
      if (!registry.exists(key) || registry[key] != source_registry[key]) begin
        mutation_guard.put(1);
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          {operation, " registry entry changed during projection"}
        );
      end
    end
    foreach (projected_registry[key])
      registry[key] = projected_registry[key];
    mutation_guard.put(1);
    return rdma_status::success();
  endfunction

  // 功能：recovery_schema_status 先为 recovery_records 的每一项建立 detached schema
  //   投影，再以受保护的全量提交替换原账本，避免 teardown 复审中途失败留下部分恢复记录。
  // 输入/输出及副作用：operation（输入）决定投影诊断前缀；成功时只更新 manager 自有
  //   recovery_records 快照，不接管 backing、mapping 或 adapter 生命周期。
  // 失败/边界：任一投影失败、mutation_guard 忙、publication_epoch 变化或原 recovery
  //   引用被替换时返回错误并保持 recovery_records 原值；外部 clone/factory 阶段不持有 guard。
  protected function rdma_status recovery_schema_status(string operation);
    rdma_recovery_record projected_records[string];
    rdma_recovery_record source_records[string];
    rdma_recovery_record projected;
    rdma_status status;
    longint unsigned epoch_snapshot;

    epoch_snapshot = publication_epoch;
    foreach (recovery_records[key]) begin
      source_records[key] = recovery_records[key];
      status = project_recovery_value(
        recovery_records[key], {operation, "_recovery_entry"}, projected
      );
      if (!status.ok())
        return status;
      if (projected == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          {operation, " recovery projection returned null"}
        );
      projected_records[key] = projected;
    end
    if (mutation_guard == null || !mutation_guard.try_get(1))
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        {operation, " recovery schema commit window is busy"}
      );
    if (publication_epoch != epoch_snapshot) begin
      mutation_guard.put(1);
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " recovery schema epoch changed during projection"}
      );
    end
    foreach (source_records[key]) begin
      if (!recovery_records.exists(key) ||
          recovery_records[key] != source_records[key]) begin
        mutation_guard.put(1);
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          {operation, " recovery entry changed during projection"}
        );
      end
    end
    foreach (projected_records[key])
      recovery_records[key] = projected_records[key];
    mutation_guard.put(1);
    return rdma_status::success();
  endfunction

  // 功能：recovery_entry_schema_status 为指定 key 建立单条 detached recovery 投影，
  //   并在 source 引用仍然有效时通过 mutation guard 原子替换该条目。
  // 输入/输出及副作用：key、operation（输入）定位 recovery 记录和诊断前缀；成功时
  //   只更新 manager 自有 recovery_records[key]，不创建或释放外部 backing。
  // 失败/边界：key 不存在时保持既有幂等成功；记录为空、投影失败、epoch/引用变化或
  //   mutation_guard 忙时返回明确错误，且不会把 detached 半成品写回账本。
  protected function rdma_status recovery_entry_schema_status(
    string key,
    string operation
  );
    rdma_recovery_record source_record;
    rdma_recovery_record projected;
    rdma_status status;
    longint unsigned epoch_snapshot;

    if (!recovery_records.exists(key))
      return rdma_status::success();
    source_record = recovery_records[key];
    if (source_record == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " recovery entry is null"}
      );
    epoch_snapshot = publication_epoch;
    status = project_recovery_value(
      source_record, {operation, "_recovery_entry"}, projected
    );
    if (!status.ok())
      return status;
    if (projected == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " recovery projection returned null"}
      );
    if (mutation_guard == null || !mutation_guard.try_get(1))
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        {operation, " recovery schema commit window is busy"}
      );
    if (publication_epoch != epoch_snapshot) begin
      mutation_guard.put(1);
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " recovery schema epoch changed during projection"}
      );
    end
    if (!recovery_records.exists(key) || recovery_records[key] != source_record) begin
      mutation_guard.put(1);
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " recovery entry changed during projection"}
      );
    end
    recovery_records[key] = projected;
    mutation_guard.put(1);
    return rdma_status::success();
  endfunction

  // 功能：commit_registry_replacement 将已经完成外部 projection、identity 和业务
  //   validation 的 resource replacement 安装到 registry，并按一次受保护窗口更新
  //   staged_allocations 与 publication_epoch。
  // 输入/输出及副作用：key、replacement、operation 为输入；mark_staged/clear_staged
  //   选择 staged 标志的单向变化；expected_epoch/source 必须来自外部校验前的快照；
  //   validate 在锁外执行，随后 guard 内只写 manager 自有 registry/staged/epoch，
  //   不调用 factory、adapter，也不取得外部 backing 所有权。
  // 失败/边界：replacement/key 缺失、handle identity 与当前 registry 不一致、业务
  //   validation 返回 null/失败、snapshot 过期/source 改变或 mutation_guard 忙时返回错误并
  //   保持原条目；mark 与 clear 同时置位属于调用方契约错误，禁止产生含糊的 staged 状态。
  protected function rdma_status commit_registry_replacement(
    string key,
    rdma_resource replacement,
    string operation,
    longint unsigned expected_epoch,
    rdma_resource expected_source,
    bit mark_staged = 1'b0,
    bit clear_staged = 1'b0
  );
    rdma_status status;

    if (key == "" || replacement == null || replacement.handle == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {operation, " registry replacement is incomplete"}
      );
    if (mark_staged && clear_staged)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {operation, " registry staged action is ambiguous"}
      );
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " registry replacement validation returned null"}
      );
    if (!status.ok())
      return status;
    if (!registry.exists(key) || registry[key] == null ||
        registry[key].handle == null ||
        !same_handle_instance(registry[key].handle, replacement.handle))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " registry replacement authority changed"}
      );
    if (mutation_guard == null || !mutation_guard.try_get(1))
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        {operation, " registry replacement commit window is busy"}
      );
    if (expected_epoch != publication_epoch) begin
      mutation_guard.put(1);
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " registry replacement is stale"}
      );
    end
    if (expected_source == null || !registry.exists(key) ||
        registry[key] != expected_source) begin
      mutation_guard.put(1);
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " registry entry changed during projection"}
      );
    end
    registry[key] = replacement;
    if (mark_staged)
      staged_allocations[key] = 1'b1;
    else if (clear_staged)
      staged_allocations.delete(key);
    advance_publication_epoch();
    mutation_guard.put(1);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中由 same_outstanding_ids 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_outstanding_ids 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_outstanding_ids(
    rdma_resource lhs,
    rdma_resource rhs
  );
    if (lhs == null || rhs == null ||
        lhs.outstanding_ids.size() != rhs.outstanding_ids.size())
      return 1'b0;
    foreach (lhs.outstanding_ids[i]) begin
      if (lhs.outstanding_ids[i] != rhs.outstanding_ids[i])
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：same_handle_instance 是 resource manager 内部 canonical handle identity
  //       比较器，按四个公开身份字段判断两个 handle 是否表示同一值。
  // 输入/输出及副作用：lhs、rhs（输入）是非拥有 handle 引用；只读取 kind、
  //       function_uid、object_id、generation，返回 bit，不修改 handle、registry、
  //       runtime 或外部 adapter，也不取得任何资源所有权。
  // 失败/边界：lhs 与 rhs 同为 null 返回 1；仅一侧为 null 返回 0；两侧非空时
  //       四个字段任一 `==` 不等返回 0。函数不执行 $isunknown，不验证
  //       authority/alias 或 generation 新鲜度；状态、路由和生命周期门禁由
  //       caller 负责。
  protected function bit same_handle_instance(rdma_handle lhs,
                                               rdma_handle rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.kind == rhs.kind &&
           lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id &&
           lhs.generation == rhs.generation;
  endfunction

  // 功能：在 rdma_resource_manager 中由 same_handle_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_handle_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_handle_value(rdma_handle lhs,
                                            rdma_handle rhs);
    return same_handle_instance(lhs, rhs);
  endfunction

  // 功能：在 rdma_resource_manager 中由 same_dependency_topology 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_dependency_topology 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_dependency_topology(rdma_resource lhs,
                                                  rdma_resource rhs);
    if (lhs == null || rhs == null ||
        lhs.dependencies.size() != rhs.dependencies.size())
      return 1'b0;
    foreach (lhs.dependencies[i]) begin
      if (!same_handle_instance(lhs.dependencies[i], rhs.dependencies[i]))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：在 rdma_resource_manager 中由 same_binding_identity 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_binding_identity 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_binding_identity(rdma_function_binding lhs,
                                               rdma_function_binding rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.function_uid != rhs.function_uid ||
        lhs.notify_bar_id != rhs.notify_bar_id ||
        lhs.notify_base != rhs.notify_base ||
        lhs.notify_size != rhs.notify_size ||
        lhs.notify_table_sel != rhs.notify_table_sel ||
        lhs.notify_table_index != rhs.notify_table_index ||
        lhs.host_id != rhs.host_id || lhs.pfvf_id != rhs.pfvf_id ||
        lhs.rdma_vf_id != rhs.rdma_vf_id ||
        lhs.global_function_id != rhs.global_function_id ||
        lhs.vsi_id != rhs.vsi_id ||
        lhs.state != rhs.state || lhs.generation != rhs.generation ||
        lhs.notify_valid != rhs.notify_valid ||
        lhs.notify_ready != rhs.notify_ready ||
        lhs.dmi_valid != rhs.dmi_valid || lhs.dmi_ready != rhs.dmi_ready ||
        lhs.vft_valid != rhs.vft_valid || lhs.vft_ready != rhs.vft_ready ||
        !same_handle_value(lhs.owner_h, rhs.owner_h))
      return 1'b0;
    if (lhs.queue_dma.requester_bdf != rhs.queue_dma.requester_bdf ||
        lhs.queue_dma.pasid_valid != rhs.queue_dma.pasid_valid ||
        lhs.queue_dma.pasid != rhs.queue_dma.pasid ||
        lhs.queue_dma.dma_domain_valid != rhs.queue_dma.dma_domain_valid ||
        lhs.queue_dma.dma_domain_id != rhs.queue_dma.dma_domain_id)
      return 1'b0;
    if (lhs.queue_caps.min_cq_depth != rhs.queue_caps.min_cq_depth ||
        lhs.queue_caps.max_cq_depth != rhs.queue_caps.max_cq_depth ||
        lhs.queue_caps.min_srq_depth != rhs.queue_caps.min_srq_depth ||
        lhs.queue_caps.max_srq_depth != rhs.queue_caps.max_srq_depth ||
        lhs.queue_caps.max_ceq_depth != rhs.queue_caps.max_ceq_depth ||
        lhs.queue_caps.max_aeq_depth != rhs.queue_caps.max_aeq_depth ||
        lhs.queue_caps.max_wq_sge != rhs.queue_caps.max_wq_sge ||
        lhs.queue_caps.max_queue_ring_bytes !=
          rhs.queue_caps.max_queue_ring_bytes ||
        lhs.queue_caps.max_sgb_bytes != rhs.queue_caps.max_sgb_bytes)
      return 1'b0;
    if (lhs.interrupt_vectors.size() != rhs.interrupt_vectors.size())
      return 1'b0;
    foreach (lhs.interrupt_vectors[i]) begin
      if (lhs.interrupt_vectors[i].function_local_vector !=
            rhs.interrupt_vectors[i].function_local_vector ||
          lhs.interrupt_vectors[i].hardware_eq_vector !=
            rhs.interrupt_vectors[i].hardware_eq_vector ||
          lhs.interrupt_vectors[i].msix_table_index !=
            rhs.interrupt_vectors[i].msix_table_index ||
          lhs.interrupt_vectors[i].enabled !=
            rhs.interrupt_vectors[i].enabled)
        return 1'b0;
    end
    if (lhs.pcie == null || rhs.pcie == null)
      return lhs.pcie == rhs.pcie;
    if (lhs.pcie.bdf != rhs.pcie.bdf ||
        lhs.pcie.parent_pf_bdf != rhs.pcie.parent_pf_bdf ||
        lhs.pcie.vf_index != rhs.pcie.vf_index ||
        lhs.pcie.mse != rhs.pcie.mse || lhs.pcie.bme != rhs.pcie.bme)
      return 1'b0;
    foreach (lhs.pcie.bar[i]) begin
      if (lhs.pcie.bar[i] == null || rhs.pcie.bar[i] == null) begin
        if (lhs.pcie.bar[i] != rhs.pcie.bar[i])
          return 1'b0;
      end
      else if (lhs.pcie.bar[i].bar_id != rhs.pcie.bar[i].bar_id ||
               lhs.pcie.bar[i].base != rhs.pcie.bar[i].base ||
               lhs.pcie.bar[i].size != rhs.pcie.bar[i].size ||
               lhs.pcie.bar[i].enabled != rhs.pcie.bar[i].enabled)
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：publication_identity_status 校验 candidate、authoritative 与当前对象状态的一致性，并显式处理“published resource identity or topology changed”；“published resource manager-owned fields changed”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：candidate（输入）、authoritative（输入）；publication_identity_status 读取 candidate、authoritative 并使用字段 fields_match；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：publication_identity_status 返回 RDMA_SC_INVALID_ARGUMENT；具体拒绝条件包括 “published resource identity or topology changed”；“published resource manager-owned fields changed”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status publication_identity_status(
    rdma_resource candidate,
    rdma_resource authoritative
  );
    rdma_function candidate_function;
    rdma_function authoritative_function;
    rdma_pd candidate_pd;
    rdma_pd authoritative_pd;
    rdma_mr candidate_mr;
    rdma_mr authoritative_mr;
    rdma_cq candidate_cq;
    rdma_cq authoritative_cq;
    rdma_qp candidate_qp;
    rdma_qp authoritative_qp;
    rdma_srq candidate_srq;
    rdma_srq authoritative_srq;
    rdma_cmq candidate_cmq;
    rdma_cmq authoritative_cmq;
    rdma_ceq candidate_ceq;
    rdma_ceq authoritative_ceq;
    rdma_aeq candidate_aeq;
    rdma_aeq authoritative_aeq;
    bit fields_match;

    if (candidate == null || authoritative == null ||
        candidate.handle == null || authoritative.handle == null ||
        candidate.handle.kind != authoritative.handle.kind ||
        !same_handle_instance(candidate.handle, authoritative.handle) ||
        !same_handle_instance(candidate.owner, authoritative.owner) ||
        !same_dependency_topology(candidate, authoritative) ||
        !same_outstanding_ids(candidate, authoritative))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "published resource identity or topology changed"
      );

    fields_match = 1'b0;
    case (authoritative.handle.kind)
      RDMA_RESOURCE_FUNCTION: begin
        if ($cast(candidate_function, candidate) &&
            $cast(authoritative_function, authoritative))
          fields_match = candidate_function.local_function_id ==
                      authoritative_function.local_function_id &&
                    candidate_function.global_function_id ==
                      authoritative_function.global_function_id &&
                    candidate_function.rdma_vf_id ==
                      authoritative_function.rdma_vf_id &&
                    candidate_function.vsi_id == authoritative_function.vsi_id &&
                    candidate_function.pfvf_id ==
                      authoritative_function.pfvf_id &&
                    same_binding_identity(candidate_function.binding,
                                          authoritative_function.binding);
      end
      RDMA_RESOURCE_PD: begin
        if ($cast(candidate_pd, candidate) &&
            $cast(authoritative_pd, authoritative))
          fields_match = candidate_pd.local_pd_id == authoritative_pd.local_pd_id &&
                    candidate_pd.global_pd_id == authoritative_pd.global_pd_id;
      end
      RDMA_RESOURCE_MR: begin
        if ($cast(candidate_mr, candidate) &&
            $cast(authoritative_mr, authoritative))
          fields_match = candidate_mr.local_mr_id == authoritative_mr.local_mr_id &&
                    candidate_mr.global_mr_id == authoritative_mr.global_mr_id &&
                    same_handle_instance(candidate_mr.pd_h,
                                         authoritative_mr.pd_h);
      end
      RDMA_RESOURCE_CQ: begin
        if ($cast(candidate_cq, candidate) &&
            $cast(authoritative_cq, authoritative))
          fields_match = candidate_cq.local_cq_id == authoritative_cq.local_cq_id &&
                    candidate_cq.global_cq_id == authoritative_cq.global_cq_id &&
                    same_handle_instance(candidate_cq.ceq_h,
                                         authoritative_cq.ceq_h);
      end
      RDMA_RESOURCE_QP: begin
        if ($cast(candidate_qp, candidate) &&
            $cast(authoritative_qp, authoritative))
          fields_match = candidate_qp.local_qp_id == authoritative_qp.local_qp_id &&
                    candidate_qp.global_qp_id == authoritative_qp.global_qp_id &&
                    same_handle_instance(candidate_qp.pd_h,
                                         authoritative_qp.pd_h) &&
                    same_handle_instance(candidate_qp.send_cq_h,
                                         authoritative_qp.send_cq_h) &&
                    same_handle_instance(candidate_qp.recv_cq_h,
                                         authoritative_qp.recv_cq_h) &&
                    same_handle_instance(candidate_qp.srq_h,
                                         authoritative_qp.srq_h);
      end
      RDMA_RESOURCE_SRQ: begin
        if ($cast(candidate_srq, candidate) &&
            $cast(authoritative_srq, authoritative))
          fields_match = candidate_srq.local_srq_id ==
                      authoritative_srq.local_srq_id &&
                    candidate_srq.global_srq_id ==
                      authoritative_srq.global_srq_id &&
                    same_handle_instance(candidate_srq.pd_h,
                                         authoritative_srq.pd_h);
      end
      RDMA_RESOURCE_CMQ: begin
        if ($cast(candidate_cmq, candidate) &&
            $cast(authoritative_cmq, authoritative))
          fields_match = candidate_cmq.local_cmq_id ==
                      authoritative_cmq.local_cmq_id &&
                    candidate_cmq.global_cmq_id ==
                      authoritative_cmq.global_cmq_id;
      end
      RDMA_RESOURCE_CEQ: begin
        if ($cast(candidate_ceq, candidate) &&
            $cast(authoritative_ceq, authoritative))
          fields_match = candidate_ceq.local_ceq_id ==
                      authoritative_ceq.local_ceq_id &&
                    candidate_ceq.global_ceq_id ==
                      authoritative_ceq.global_ceq_id;
      end
      RDMA_RESOURCE_AEQ: begin
        if ($cast(candidate_aeq, candidate) &&
            $cast(authoritative_aeq, authoritative))
          fields_match = candidate_aeq.local_aeq_id ==
                      authoritative_aeq.local_aeq_id &&
                    candidate_aeq.global_aeq_id ==
                      authoritative_aeq.global_aeq_id;
      end
    endcase
    if (!fields_match)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "published resource manager-owned fields changed"
      );
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_public_resource_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_public_resource_value 读取 source、copy_label、result 并使用字段 status、result，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_public_resource_value 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status project_public_resource_value(
    rdma_resource source,
    string copy_label,
    output rdma_resource result
  );
    rdma_status status;

    status = project_resource_value(source, copy_label, result);
    if (!status.ok())
      return status;
    status = publication_identity_status(result, source);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，project_public_recovery_value 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：source（输入）、copy_label（输入）、result（输出）；project_public_recovery_value 读取 source、copy_label、result 并使用输入参数和固定枚举/常量，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：project_public_recovery_value 的结果直接由 return project_recovery_value(source, copy_label, result) 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  protected function rdma_status project_public_recovery_value(
    rdma_recovery_record source,
    string copy_label,
    output rdma_recovery_record result
  );
    return project_recovery_value(source, copy_label, result);
  endfunction

  // 功能：recovery_ready 比较 recovery 与当前 authority/状态字段，返回布尔结果供上层执行精确分支。
  // 输入/输出及副作用：recovery（输入）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：当前状态不允许、epoch/generation 过期或恢复证据不完整时返回错误；不得跳过隔离步骤。
  protected function bit recovery_ready(rdma_recovery_record recovery);
    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.pending_steps.size() != 0)
      return 1'b0;
    if (recovery.qp_recovery_valid && recovery.qp_recovery != null &&
        recovery.qp_recovery.intent == RDMA_QP_RECOVER_CREATE_ROLLBACK &&
        recovery.qp_recovery.candidate_qpc == null &&
        recovery.qp_recovery.prior_qpc == null &&
        recovery.qp_recovery.context_ref == null) begin
      if (recovery.qp_recovery.qp_plan == null ||
          !qp_plan_cleanup_ready(recovery.qp_recovery.qp_plan))
        return 1'b0;
      if (recovery.qp_recovery.staging_mapping != null ||
          recovery.qp_recovery.query_mapping != null ||
          recovery.qp_recovery.ambiguous_ticket != null ||
          recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE)
        return 1'b0;
    end
    return 1'b1;
  endfunction
  // 功能：在 rdma_resource_manager 中，binding_handle_value 把 binding_handle_value 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：binding（输入）、handle_name（输入）；binding_handle_value 先依据 依赖存在性、authority 和 generation 条件 校验 binding、handle_name；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_function_handle。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
  protected function rdma_function_handle binding_handle_value(
    rdma_function_binding binding,
    string handle_name
  );
    rdma_function_handle result;

    result = new(handle_name);
    result.kind = RDMA_RESOURCE_FUNCTION;
    result.function_uid = binding.function_uid;
    result.object_id = binding.global_function_id;
    result.generation = binding.generation;
    return result;
  endfunction

  // 功能：在 rdma_resource_manager 中，source_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：binding（输入）、key（输出）；source_key 读取 binding、key 并使用字段 key，并写入 key；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：source_key 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function bit source_key(
    rdma_function_binding binding,
    output string key
  );
    key = "";
    foreach (generation_sources[candidate_key]) begin
      if (generation_sources[candidate_key] == binding) begin
        key = candidate_key;
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  // 功能：refresh_generation 从已登记的 source 观察代际，单调推进 high-water 并记住 32 位 wrap。
  // 输入/输出及副作用：key 定位 generation_sources，读取其 generation；必要时更新
  //   generation_high_water 或置 generation_exhausted，不投影 source、不调用 factory。
  // 失败/边界：source 不存在或为空时无操作；回退值不降低 high-water，已观察到最大值后
  //   再见零永久标记 exhausted，不能因后续请求失败而撤销这份观察证据。
  protected function void refresh_generation(string key);
    int unsigned observed_generation;

    if (!generation_sources.exists(key) ||
        generation_sources[key] == null)
      return;
    observed_generation = generation_sources[key].generation;
    if (generation_high_water.exists(key) &&
        generation_high_water[key] == 32'hffff_ffff &&
        observed_generation == 0)
      generation_exhausted[key] = 1'b1;
    if (!generation_high_water.exists(key) ||
        observed_generation > generation_high_water[key])
      generation_high_water[key] = observed_generation;
  endfunction

  // 功能：在 rdma_resource_manager 中，binding_context_status 把 binding_context_status 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：binding（输入）、trusted_binding（输出）、owner（输出）、key（输出）、registration_needed（输出）；binding_context_status 读取 binding、trusted_binding、owner、key、registration_needed 并使用字段 trusted_binding、owner、key、registration_needed、status、source_is_known、observed_generation、trusted_binding.generation，并写入 trusted_binding、owner、key、registration_needed；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
  protected function rdma_status binding_context_status(
    rdma_function_binding binding,
    output rdma_function_binding trusted_binding,
    output rdma_function_handle owner,
    output string key,
    output bit registration_needed
  );
    rdma_status status;
    rdma_function_binding projected_binding;
    int unsigned observed_generation;
    bit source_is_known;

    trusted_binding = null;
    owner = null;
    key = "";
    registration_needed = 1'b0;
    if (binding == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "function binding is null");
    status = project_binding_value(binding, "binding input",
                                   projected_binding);
    if (!status.ok())
      return status;
    status = registry_schema_status("binding context");
    if (!status.ok())
      return status;

    source_is_known = source_key(binding, key);
    if (!source_is_known) begin
      key = $sformatf("%016h:%08h", projected_binding.function_uid,
                      projected_binding.global_function_id);
      if (binding_snapshots.exists(key))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "Function generation source is not the registered binding"
        );
    end

    if (!binding_snapshots.exists(key)) begin
      status = projected_binding.validate();
      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Function binding validation returned null"
        );
      if (!status.ok())
        return status;
      if (projected_binding.state != RDMA_BIND_ACTIVE)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "function binding is not ACTIVE");
      trusted_binding = projected_binding;
      observed_generation = projected_binding.generation;
      registration_needed = 1'b1;
    end
    else begin
      status = project_binding_value(binding_snapshots[key],
                                   "trusted binding", trusted_binding);
      if (!status.ok())
        return status;
      observed_generation = projected_binding.generation;
      if (!generation_high_water.exists(key))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "Function generation ledger is missing");
      if (generation_exhausted.exists(key))
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "Function generation counter is permanently exhausted"
        );
      if (observed_generation < generation_high_water[key]) begin
        if (generation_high_water[key] == 32'hffff_ffff &&
            observed_generation == 0) begin
          generation_exhausted[key] = 1'b1;
          return rdma_status::make(
            RDMA_SC_RESOURCE_EXHAUSTED,
            "Function generation wrapped after 32-bit exhaustion"
          );
        end
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "Function generation moved backwards");
      end
      if (observed_generation > generation_high_water[key])
        generation_high_water[key] = observed_generation;
    end

    trusted_binding.generation = observed_generation;
    status = trusted_binding.synchronize_identity_from_legacy_mirrors();
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "trusted binding identity synchronization returned null"
      ) : status;
    trusted_binding.owner_h = binding_handle_value(
      trusted_binding, "trusted_binding_owner"
    );
    owner = binding_handle_value(trusted_binding, "binding_owner");
    if (retired_generations.exists(function_generation_key(owner)))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function generation is retired");
    status = trusted_binding.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Trusted Function binding validation returned null"
      );
    if (!status.ok())
      return status;
    if (trusted_binding.state != RDMA_BIND_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "function binding is not ACTIVE");
    return rdma_status::success();
  endfunction

  // 功能：commit_identity_reservation 原子完成首次 binding 登记和一次 local-ID/serial 消费，
  //   使普通资源与 Function 使用同一 allocator 提交边界，而非先登记再跨 factory 消费。
  // 输入/输出及副作用：source 借用代际来源，trusted_binding/owner/kind 是已准入快照，
  //   registration_needed 指明首次登记，expected_epoch 冻结于 admission 之前；输出 local_id、
  //   used_free_id、registered_binding、prior_serial、reservation_epoch 供发布/补偿使用。
  // 失败/边界：caller 已检查类型、容量与 Function incarnation；投影失败、锁忙、旧/饱和
  //   epoch、登记来源变化或 generation/retirement 漂移均不消费 ID。generation high-water
  //   可单调刷新；成功恰好推进一次 epoch，锁内及返回 status 不经过 factory 或外部 adapter。
  protected function rdma_status commit_identity_reservation(
    rdma_function_binding source,
    rdma_function_binding trusted_binding,
    rdma_function_handle owner,
    rdma_resource_kind_e kind,
    bit registration_needed,
    longint unsigned expected_epoch,
    output int unsigned local_id,
    output bit used_free_id,
    output bit registered_binding,
    output int unsigned prior_serial,
    output longint unsigned reservation_epoch
  );
    rdma_function_binding binding_copy;
    rdma_status status;
    string key;

    local_id = '0;
    used_free_id = 1'b0;
    registered_binding = 1'b0;
    prior_serial = '0;
    reservation_epoch = '0;
    if (registration_needed) begin
      status = project_binding_value(trusted_binding, "binding registry", binding_copy);
      if (!status.ok())
        return status;
    end
    key = function_key(owner);
    if (mutation_guard == null || !mutation_guard.try_get(1))
      return rdma_status::make_direct(RDMA_SC_RESOURCE_BUSY,
                                     "identity reservation commit window is busy");
    if (publication_epoch != expected_epoch || expected_epoch == '1) begin
      mutation_guard.put(1);
      return rdma_status::make_direct(RDMA_SC_INVALID_STATE,
                                     "identity reservation admission epoch changed or exhausted");
    end
    if (registration_needed ? (binding_snapshots.exists(key) || generation_sources.exists(key)) :
        (!binding_snapshots.exists(key) || !generation_sources.exists(key) ||
         generation_sources[key] != source)) begin
      mutation_guard.put(1);
      return rdma_status::make_direct(RDMA_SC_INVALID_STATE,
                                     "identity reservation binding registration changed");
    end
    refresh_generation(key);
    if (source.generation != owner.generation || generation_exhausted.exists(key) ||
        retired_generations.exists(function_generation_key(owner)) ||
        (!registration_needed && (!generation_high_water.exists(key) ||
                                  generation_high_water[key] != owner.generation))) begin
      mutation_guard.put(1);
      return rdma_status::make_direct(RDMA_SC_STALE_GENERATION,
                                     "identity reservation Function generation changed");
    end

    // 先前的容量/incarnation admission 与此处之间只允许 epoch 不变；以下均为 manager
    // 自有字段操作，不能增加 status factory、clone 或 adapter 回调。binding 与 ID 同时生效。
    used_free_id = free_local_ids.exists(kind) && free_local_ids[kind].size() != 0;
    consume_local_id(kind, used_free_id, local_id);
    if (kind != RDMA_RESOURCE_FUNCTION) begin
      prior_serial = next_object_serial[kind];
      next_object_serial[kind] = prior_serial == 0 ? 2 : prior_serial + 1;
    end
    if (registration_needed) begin
      generation_sources[key] = source;
      binding_snapshots[key] = binding_copy;
      generation_high_water[key] = owner.generation;
      registered_binding = 1'b1;
    end
    advance_publication_epoch();
    reservation_epoch = publication_epoch;
    mutation_guard.put(1);
    return rdma_status::make_direct(RDMA_SC_OK);
  endfunction

  // 功能：active_binding_status 校验 binding、owner 与当前对象状态的一致性，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：binding（输入）、owner（输出）；active_binding_status 读取 binding、owner 并使用输入参数和固定枚举/常量，并写入 owner；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：active_binding_status 只读输入并返回 rdma_status；边界由函数体现有分支决定，不修改状态或转移资源。
  protected function rdma_status active_binding_status(
    rdma_function_binding binding,
    output rdma_function_handle owner
  );
    rdma_function_binding trusted_binding;
    string key;
    bit registration_needed;

    return binding_context_status(binding, trusted_binding, owner, key,
                                  registration_needed);
  endfunction

  // 功能：owner_binding_status 校验 owner 与当前对象状态的一致性，并显式处理“registry owner is not a Function handle”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：owner（输入）；owner_binding_status 读取 owner 并使用字段 key、generation_key；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：owner_binding_status 返回 RDMA_SC_INVALID_STATE、RDMA_SC_STALE_GENERATION；典型拒绝条件为“registry owner is not a Function handle”“Function binding is not registered”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status owner_binding_status(
    rdma_function_handle owner
  );
    string key;
    string generation_key;

    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "registry owner is not a Function handle");
    key = function_key(owner);
    if (!binding_snapshots.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function binding is not registered");
    refresh_generation(key);
    generation_key = function_generation_key(owner);
    if (retired_generations.exists(generation_key))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function generation is retired");
    if (generation_exhausted.exists(key))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function generation counter is exhausted");
    if (!generation_high_water.exists(key) ||
        generation_high_water[key] != owner.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function generation is not current");
    return rdma_status::success();
  endfunction

  // 功能：判断 has_conflicting_generation 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：owner（输入）；has_conflicting_generation 读取 owner 并使用字段 registry、key；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：has_conflicting_generation 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected function bit has_conflicting_generation(
    rdma_function_handle owner
  );
    foreach (registry[key]) begin
      if (registry[key].owner != null &&
          registry[key].owner.function_uid == owner.function_uid &&
          registry[key].owner.object_id == owner.object_id &&
          registry[key].owner.kind == owner.kind &&
          registry[key].owner.generation != owner.generation)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：reserve_identity 为普通资源预留 local ID 与唯一 incarnation serial，尚不发布 registry。
  // 输入/输出及副作用：binding/kind 提供 authority/资源类型；owner/handle/local_id 返回预留身份，
  //   used_free_id/registered_binding/prior_serial/reservation_epoch 返回补偿依据。prior_serial
  //   由共同 commit 在消费时填充；入口先冻结 admission epoch，成功更新 allocator/首次
  //   binding 并推进一次 epoch，再构造 handle，不在 factory 返回后重采样提交证据。
  // 失败/边界：binding/schema 失败、未知或 FUNCTION kind、serial/local-ID 耗尽、旧代际仍有
  //   资源、binding 投影失败、锁忙或旧/饱和 admission epoch 均拒绝，不消费 ID；成功
  //   预留必须由 caller 发布或补偿一次，generation observer 的单调观察不回滚。
  protected function rdma_status reserve_identity(
    rdma_function_binding binding,
    rdma_resource_kind_e kind,
    output rdma_function_handle owner,
    output rdma_handle handle,
    output int unsigned local_id,
    output bit used_free_id,
    output bit registered_binding,
    output int unsigned prior_serial,
    output longint unsigned reservation_epoch
  );
    rdma_status status;
    rdma_function_binding trusted_binding;
    int unsigned serial;
    string owner_key;
    bit registration_needed;
    bit has_free_id;
    longint unsigned admission_epoch;

    owner = null;
    handle = null;
    local_id = '0;
    used_free_id = 1'b0;
    registered_binding = 1'b0;
    prior_serial = '0;
    reservation_epoch = '0;
    admission_epoch = publication_epoch;
    status = binding_context_status(binding, trusted_binding, owner,
                                    owner_key, registration_needed);
    if (!status.ok())
      return status;
    if (!valid_kind(kind) || kind == RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "object resource kind is invalid");

    // 保留 serial、local ID、旧代际资源的既有错误优先级；这些是准备阶段的检查，
    // commit 必须再确认入口 epoch，不能把外部窗口后的旧检查结果当作新的分配依据。
    serial = next_object_serial[kind];
    if (serial == 0)
      serial = 1;
    if (serial > 32'h0fff_ffff)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "resource incarnation serial is exhausted");
    status = local_id_status(kind, has_free_id);
    if (!status.ok())
      return status;

    if (has_conflicting_generation(owner))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "older Function generation still owns live resources"
      );
    status = commit_identity_reservation(binding, trusted_binding, owner, kind,
      registration_needed, admission_epoch, local_id, used_free_id,
      registered_binding, prior_serial, reservation_epoch);
    if (!status.ok())
      return status;

    serial = prior_serial == 0 ? 1 : prior_serial;
    handle = new("resource_handle");
    handle.kind = kind;
    handle.function_uid = owner.function_uid;
    handle.object_id = {kind, serial[27:0]};
    handle.generation = owner.generation;
    return rdma_status::success();
  endfunction

  // 功能：reserve_identity_candidate 把 manager 的一次 identity 预留结果封装为 detached
  //   candidate，供 create_* 入口在构造 authoritative resource 前暂存完整回滚证据。
  // 输入/输出及副作用：binding（输入）、kind（输入）、candidate（输出）；函数调用
  //   reserve_identity 更新 manager 自有 allocator/binding registration，并写入 candidate 的
  //   owner、handle、manager_epoch、local_id、serial 和回滚标记；成功时不发布 registry resource。
  // 失败/边界：kind 非对象资源、容量/ID/代际校验失败或 candidate 构造失败时原样返回错误；
  //   失败不保留 candidate，也不允许 create_* 继续构造部分 authoritative resource；
  //   reserve_identity 已冻结一次消费对应的 epoch，本层不重采样或重复推进。
  protected function rdma_status reserve_identity_candidate(
    rdma_function_binding binding,
    rdma_resource_kind_e kind,
    output rdma_resource_identity_candidate candidate
  );
    rdma_status status;

    candidate = new("resource_identity_candidate");
    candidate.kind = kind;
    status = reserve_identity(binding, kind, candidate.owner, candidate.handle,
                              candidate.local_id, candidate.used_free_id,
                              candidate.registered_binding,
                              candidate.prior_serial, candidate.manager_epoch);
    if (!status.ok()) begin
      candidate = null;
      return status;
    end
    if (!candidate.valid()) begin
      // reserve_identity() 已经推进过 allocator；即使 candidate 形状校验失败，也必须
      // 在丢弃对象前撤销同一组 manager-owned 预留，避免 future factory seam 泄漏 ID/serial。
      if (candidate.owner != null)
        rollback_identity_reservation(candidate.kind, candidate.owner,
                                      candidate.local_id,
                                      candidate.used_free_id,
                                      candidate.registered_binding,
                                      candidate.prior_serial,
                                      candidate.manager_epoch);
      candidate.clear();
      candidate = null;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "identity reservation candidate is incomplete"
      );
    end
    return rdma_status::success();
  endfunction

  // 功能：rollback_identity_candidate 撤销尚未发布的普通资源预留；无交错 mutation 时恢复
  //   分配前账本，旧 epoch 时只归还自身 local ID，保留后续 serial/binding。
  // 输入/输出及副作用：candidate 提供 kind/owner/local_id、来源标志、prior_serial 与
  //   manager_epoch；委托公共补偿后清空 candidate，不删除任何已发布 registry 条目。
  // 失败/边界：null 或已 clear 的 candidate 幂等无操作；仅限 manager 自建、未发布且未被
  //   篡改的预留，已发布资源须走 finalize/release，不得用此入口释放。
  protected function void rollback_identity_candidate(
    rdma_resource_identity_candidate candidate
  );
    if (candidate == null)
      return;
    if (candidate.valid())
      rollback_identity_reservation(candidate.kind, candidate.owner,
                                    candidate.local_id,
                                    candidate.used_free_id,
                                    candidate.registered_binding,
                                    candidate.prior_serial,
                                    candidate.manager_epoch);
    candidate.clear();
  endfunction

  // 功能：publish_identity_candidate 统一普通资源 create_* 的 detached candidate
  //   发布阶段：校验 identity 与 authoritative 形状，登记 registry/代际快照，并在
  //   register_resource 失败时撤销尚未发布的 allocator reservation。
  // 输入/输出及副作用：candidate、authoritative、copy_label 为输入，published 为输出；
  //   成功时 published 是 register_resource 产生的 detached 快照且 candidate 被清除，
  //   失败时 candidate 仍由本 helper 回滚并清除，不修改已存在的 registry 条目。
  // 失败/边界：candidate 为空/不完整、authoritative 为空或 handle/owner 缺失时返回
  //   INVALID_STATE；candidate epoch 落后时仅返还自身 local ID，保留后续分配账本；register_resource
  //   返回 null/失败时透传或归一化状态并执行回滚；
  //   本 helper 只适用于普通对象 candidate，Function 的 generation/tombstone 语义必须
  //   继续由 create_function 使用专用 candidate 路径处理。
  protected function rdma_status publish_identity_candidate(
    rdma_resource_identity_candidate candidate,
    rdma_resource authoritative,
    string copy_label,
    output rdma_resource published
  );
    rdma_status status;

    published = null;
    if (candidate == null || !candidate.valid())
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "resource identity candidate is incomplete before publish"
      );
    if (candidate.manager_epoch != publication_epoch) begin
      rollback_identity_candidate(candidate);
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "resource identity candidate is stale"
      );
    end
    if (authoritative == null || authoritative.owner == null ||
        authoritative.handle == null)
      begin
        rollback_identity_candidate(candidate);
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "authoritative resource is incomplete before publish"
        );
      end

    status = register_resource(authoritative, copy_label, published);
    if (status == null || !status.ok()) begin
      rollback_identity_candidate(candidate);
      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          {copy_label, " registry publication returned null status"}
        );
      return status;
    end
    if (published == null) begin
      rollback_identity_candidate(candidate);
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {copy_label, " registry publication returned no resource"}
      );
    end
    candidate.clear();
    return status;
  endfunction

  // 功能：publish_function_identity_candidate 收束 Function 专用 candidate 的 freshness、
  //   authoritative 完整性与 registry publication，避免 create_function 重新复制回滚骨架。
  // 输入/输出及副作用：candidate、authoritative 为输入，published 为输出；成功时调用
  //   register_resource 写入 manager publication ledger 并清除 candidate，失败时回滚
  //   Function local-ID reservation；只有同 epoch 的独占失败才撤销首次 binding，不接管外部所有权。
  // 失败/边界：candidate 为空/不完整、epoch 落后或 authoritative owner/handle 缺失时返回
  //   INVALID_STATE；register_resource 返回 null/失败或未返回 published 时透传/归一化错误，
  //   所有失败分支均不得留下部分 Function publication。
  protected function rdma_status publish_function_identity_candidate(
    rdma_function_identity_candidate candidate,
    rdma_function authoritative,
    output rdma_resource published
  );
    rdma_status status;

    published = null;
    if (candidate == null || !candidate.valid())
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function identity candidate is incomplete before publish"
      );
    if (candidate.manager_epoch != publication_epoch) begin
      rollback_function_identity_candidate(candidate);
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function identity candidate is stale"
      );
    end
    if (authoritative == null || authoritative.owner == null ||
        authoritative.handle == null) begin
      rollback_function_identity_candidate(candidate);
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function authoritative resource is incomplete before publish"
      );
    end
    status = register_resource(authoritative, "create Function", published);
    if (status == null || !status.ok()) begin
      rollback_function_identity_candidate(candidate);
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function registry publication returned null status"
      ) : status;
    end
    if (published == null) begin
      rollback_function_identity_candidate(candidate);
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function registry publication returned no resource"
      );
    end
    candidate.clear();
    return rdma_status::success();
  endfunction

  // 功能：reserve_function_identity_candidate 收束 Function 创建专用的 generation、tombstone
  //   与 local-ID 预留，把 create_function 的回滚证据封装为 detached candidate。
  // 输入/输出及副作用：binding（输入）提供 Function authority；candidate（输出）接收
  //   trusted binding、owner、handle、local ID、free-list 来源和首次 registration 标记；
  //   入口冻结 admission epoch，锁外完成 handle/binding 准备，共同 commit 更新
  //   manager 的 binding/allocator 账本，但不发布 Function resource。
  // 失败/边界：binding 为空、重复 incarnation、旧 generation 仍存活、tombstone 已存在、
  //   Function local-ID exhausted、handle/binding 投影失败、提交锁忙或旧/饱和 epoch 时
  //   返回错误；失败不得遗留 ID、首次 binding registration 或半成品 candidate。
  protected function rdma_status reserve_function_identity_candidate(
    rdma_function_binding binding,
    output rdma_function_identity_candidate candidate
  );
    rdma_status status;
    bit registration_needed;
    bit has_free_id;
    int unsigned unused_serial;
    longint unsigned admission_epoch;

    admission_epoch = publication_epoch;
    candidate = new("function_identity_candidate");
    status = binding_context_status(binding, candidate.trusted_binding,
                                    candidate.owner, candidate.owner_key,
                                    registration_needed);
    if (!status.ok()) begin
      candidate = null;
      return status;
    end
    if (registry.exists(resource_key(candidate.owner))) begin
      candidate.clear();
      candidate = null;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function incarnation already exists"
      );
    end
    if (has_conflicting_generation(candidate.owner)) begin
      candidate.clear();
      candidate = null;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "older Function generation still owns live resources"
      );
    end
    if (incarnation_owners.exists(incarnation_key(candidate.owner))) begin
      candidate.clear();
      candidate = null;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function incarnation was already released"
      );
    end
    status = local_id_status(RDMA_RESOURCE_FUNCTION, has_free_id);
    if (!status.ok()) begin
      candidate.clear();
      candidate = null;
      return status;
    end
    status = project_function_handle_value(
      candidate.owner, "Function identity handle", candidate.handle
    );
    if (!status.ok()) begin
      candidate.clear();
      candidate = null;
      return status;
    end
    status = commit_identity_reservation(binding, candidate.trusted_binding,
      candidate.owner, RDMA_RESOURCE_FUNCTION, registration_needed, admission_epoch,
      candidate.local_id, candidate.used_free_id, candidate.registered_binding,
      unused_serial, candidate.manager_epoch);
    if (!status.ok()) begin
      candidate.clear();
      candidate = null;
      return status;
    end
    if (!candidate.valid()) begin
      rollback_identity_reservation(RDMA_RESOURCE_FUNCTION, candidate.owner,
                                    candidate.local_id, candidate.used_free_id,
                                    candidate.registered_binding, '0,
                                    candidate.manager_epoch);
      candidate.clear();
      candidate = null;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function identity reservation candidate is incomplete"
      );
    end
    return rdma_status::success();
  endfunction

  // 功能：rollback_function_identity_candidate 将 Function 未发布预留交给同一 epoch-aware
  //   补偿流程，Function 不参与普通对象的 serial 恢复。
  // 输入/输出及副作用：candidate 提供 owner/local_id、来源和 manager_epoch；补偿后清空
  //   transient 证据，不删除已发布 Function、其它资源的 binding 或 incarnation tombstone。
  // 失败/边界：null/已 clear 的 candidate 幂等；仅限可信未发布预留；过期 epoch 只返还 ID，
  //   不回退新分配游标，也不移除窗口内后续资源共享的 binding。
  protected function void rollback_function_identity_candidate(
    rdma_function_identity_candidate candidate
  );
    if (candidate == null)
      return;
    if (candidate.valid()) begin
      rollback_identity_reservation(RDMA_RESOURCE_FUNCTION, candidate.owner,
                                    candidate.local_id, candidate.used_free_id,
                                    candidate.registered_binding, '0,
                                    candidate.manager_epoch);
    end
    candidate.clear();
  endfunction

  // 功能：rollback_local_id_reservation 返还本次预留的 local ID；独占 fresh 分配可恢复尾游标，
  //   有交错 mutation 的预留则进入 free-list，避免递减游标撞上后续已分配 ID。
  // 输入/输出及副作用：kind/local_id 定位预留，used_free_id 表示来自空闲池，exclusive 表示
  //   预留后无其它 mutation；只修改该 kind 的 free-list、next_local_id 或 exhausted 标志。
  // 失败/边界：caller 保证是有效、未发布、恰好补偿一次的 ID；达到硬件上限时仅独占回滚
  //   能清 exhausted，过期回滚保留饱和状态并返还 ID，不进行 32 位上限加一运算。
  protected function void rollback_local_id_reservation(
    rdma_resource_kind_e kind,
    int unsigned local_id,
    bit used_free_id,
    bit exclusive
  );
    if (used_free_id || !exclusive)
      free_local_ids[kind].push_front(local_id);
    else if (fresh_local_id_exhausted.exists(kind) &&
             fresh_local_id_exhausted[kind] &&
             local_id == local_id_limit(kind))
      fresh_local_id_exhausted.delete(kind);
    else if (next_local_id[kind] != 0)
      next_local_id[kind]--;
  endfunction

  // 功能：rollback_binding_registration 撤销独占失败预留首次登记且代际未变化的 binding。
  // 输入/输出及副作用：owner 定位 binding，registered_binding 表示可撤销的首次登记；
  //   先刷新单调 generation 观察值，仅仍等于 owner.generation 时删除四份 binding 记录。
  // 失败/边界：caller 必须先证明无交错 allocator mutation；非首次登记、已观察到新 generation
  //   或 generation exhausted 时保留记录，不能用失败预留抹掉 reset/wrap 证据。
  protected function void rollback_binding_registration(
    rdma_function_handle owner,
    bit registered_binding
  );
    string owner_key;

    if (!registered_binding)
      return;
    owner_key = function_key(owner);
    refresh_generation(owner_key);
    if (!generation_high_water.exists(owner_key) ||
        generation_high_water[owner_key] != owner.generation ||
        generation_exhausted.exists(owner_key))
      return;
    generation_sources.delete(owner_key);
    binding_snapshots.delete(owner_key);
    generation_high_water.delete(owner_key);
    generation_exhausted.delete(owner_key);
  endfunction

  // 功能：rollback_identity_reservation 统一普通对象与 Function 的未发布预留补偿，只撤销
  //   本次仍独占的账本变化；有交错 mutation 时只返还自身 ID，不倒退全局分配状态。
  // 输入/输出及副作用：kind/owner/local_id、used_free_id/registered_binding、prior_serial
  //   与 reservation_epoch 来自可信 candidate；补偿恰好推进一次 publication_epoch，不调用
  //   factory/adapter、不创建新账本或锁、不删除已发布资源。
  // 失败/边界：仅 candidate wrapper 可对有效预留调用一次；epoch 不同或已饱和时禁止恢复
  //   游标/serial/binding。Function 无普通对象 serial；binding 的新 generation/wrap 证据保留。
  protected function void rollback_identity_reservation(
    rdma_resource_kind_e kind,
    rdma_function_handle owner,
    int unsigned local_id,
    bit used_free_id,
    bit registered_binding,
    int unsigned prior_serial,
    longint unsigned reservation_epoch
  );
    bit exclusive;

    exclusive = reservation_epoch == publication_epoch && reservation_epoch != '1;
    rollback_local_id_reservation(kind, local_id, used_free_id, exclusive);
    if (exclusive && kind != RDMA_RESOURCE_FUNCTION)
      next_object_serial[kind] = prior_serial;
    rollback_binding_registration(owner, registered_binding && exclusive);
    advance_publication_epoch();
  endfunction

  // 功能：stage_resource_publication 在任何 registry/代际账本写入前完成一次资源发布所需
  //   的全部 detached 投影，并把稳定 key 与两个 resource snapshot 收束到 candidate。
  // 输入/输出及副作用：resource、copy_label 为输入，candidate 为输出；函数可能调用
  //   project_resource_value 等 factory/clone hook，但只写 candidate，不修改 registry、
  //   incarnation_owners、incarnation_handles、known_generations 或 allocator。
  // 失败/边界：resource/owner/handle 为空、任一 projection 返回 null/失败、key 身份不一致
  //   或 candidate.valid() 失败时返回明确状态；失败路径清除 candidate，caller 不得提交
  //   半成品，也不能以默认 key 继续 commit。
  protected function rdma_status stage_resource_publication(
    rdma_resource resource,
    string copy_label,
    output rdma_resource_publication_candidate candidate
  );
    rdma_status status;

    candidate = new("resource_publication_candidate");
    // projection 可能触发外部 clone/factory 或 completion 查询；先锁存
    // manager epoch，返回后再确认这些非拥有调用没有重入修改 registry/allocator。
    candidate.manager_epoch = publication_epoch;
    status = project_resource_value(
      resource, {copy_label, " registry"}, candidate.registry_copy
    );
    if (status == null || !status.ok()) begin
      candidate.clear();
      candidate = null;
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {copy_label, " registry projection returned null status"}
      ) : status;
    end
    status = project_resource_value(
      candidate.registry_copy, copy_label, candidate.published
    );
    if (status == null || !status.ok()) begin
      candidate.clear();
      candidate = null;
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {copy_label, " published projection returned null status"}
      ) : status;
    end
    status = project_function_handle_value(
      resource.owner, "resource_incarnation_owner", candidate.owner_copy
    );
    if (status == null || !status.ok()) begin
      candidate.clear();
      candidate = null;
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {copy_label, " owner projection returned null status"}
      ) : status;
    end
    status = project_handle_value(
      resource.handle, "resource_incarnation", candidate.handle_copy
    );
    if (status == null || !status.ok()) begin
      candidate.clear();
      candidate = null;
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {copy_label, " handle projection returned null status"}
      ) : status;
    end
    if (resource == null || resource.owner == null || resource.handle == null ||
        candidate.owner_copy == null || candidate.handle_copy == null) begin
      candidate.clear();
      candidate = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " publication identity is incomplete"}
      );
    end

    candidate.registry_key = resource_key(resource.handle);
    candidate.incarnation_key = incarnation_key(resource.handle);
    candidate.generation_key = function_generation_key(resource.owner);
    if (candidate.manager_epoch != publication_epoch) begin
      candidate.clear();
      candidate = null;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {copy_label, " manager mutated during publication projection"}
      );
    end
    if (!candidate.valid()) begin
      candidate.clear();
      candidate = null;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {copy_label, " publication candidate is inconsistent"}
      );
    end
    return rdma_status::success();
  endfunction

  // 功能：commit_resource_publication 将已完成 stage 且通过 identity 校验的 candidate 一次
  //   性写入 registry、incarnation owner/handle 和 known generation，完成 manager 唯一的
  //   resource publication mutation。
  // 输入/输出及副作用：candidate 为输入，成功时更新 manager 的四份 publication 账本；函数
  //   不调用 factory/clone hook，不创建外部对象，也不接管 adapter/backing 生命周期。
  // 失败/边界：mutation_guard 为空或已被其他最终提交占用时返回
  //   RDMA_SC_RESOURCE_BUSY 且不读取或修改账本；candidate 为空、valid() 失败、epoch 过期或
  //   registry/incarnation key 已经存在时返回 RDMA_SC_INVALID_STATE 且不修改任何账本；成功后
  //   candidate 仍保留 detached output，caller 负责复制 published 并随后 clear candidate。该
  //   重复 key 检查防止 stage→commit 间的旧 candidate 覆盖后来发布的同一 incarnation。
  protected function rdma_status commit_resource_publication(
    rdma_resource_publication_candidate candidate
  );
    rdma_status status;

    if (mutation_guard == null || !mutation_guard.try_get(1))
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "resource publication commit window is busy"
      );

    status = rdma_status::success();
    if (candidate == null || !candidate.valid())
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "resource publication candidate is incomplete before commit"
      );
    else if (candidate.manager_epoch != publication_epoch)
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "resource publication candidate is stale"
      );
    else if (registry.exists(candidate.registry_key) ||
             incarnation_owners.exists(candidate.incarnation_key) ||
             incarnation_handles.exists(candidate.incarnation_key))
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "resource publication identity is already committed"
      );
    else begin
      registry[candidate.registry_key] = candidate.registry_copy;
      incarnation_owners[candidate.incarnation_key] = candidate.owner_copy;
      incarnation_handles[candidate.incarnation_key] = candidate.handle_copy;
      known_generations[candidate.generation_key] = 1'b1;
      advance_publication_epoch();
    end
    mutation_guard.put(1);
    return status;
  endfunction

  // 功能：register_resource 兼容既有 create_* / Function 入口，把 publication 分为
  //   detached stage 与无外部调用 commit 两段，并将成功快照返回给 caller。
  // 输入/输出及副作用：resource、copy_label 为输入，published 为输出；stage 阶段只生成
  //   candidate，commit 阶段才更新 manager registry/代际账本，成功后 published 为 detached
  //   resource，失败保持 published=null 且不发布半成品。
  // 失败/边界：任何投影、candidate 校验或 commit 前置失败均原样/归一化返回；本入口不做
  //   隐式重试，也不允许外部 callback 在第二次投影中改变 publication identity。
  protected function rdma_status register_resource(
    rdma_resource resource,
    string copy_label,
    output rdma_resource published
  );
    rdma_resource_publication_candidate candidate;
    rdma_status status;

    published = null;
    status = stage_resource_publication(resource, copy_label, candidate);
    if (!status.ok())
      return status;
    status = commit_resource_publication(candidate);
    if (status == null || !status.ok()) begin
      candidate.clear();
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {copy_label, " publication commit returned null status"}
      ) : status;
    end
    published = candidate.published;
    candidate.clear();
    return rdma_status::success();
  endfunction

  // 功能：related_incarnation_owner 按 Function UID、kind 和 object ID 查找任一已知
  //   incarnation，并返回其 owner 快照。
  // 输入/输出及副作用：handle（输入）、owner（输出）；函数读取 handle 和 owner，写入
  //   owner 输出，不取得调用方资源所有权。
  // 失败/边界：related_incarnation_owner 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function bit related_incarnation_owner(
    rdma_handle handle,
    output rdma_function_handle owner
  );
    owner = null;
    foreach (incarnation_handles[key]) begin
      if (incarnation_handles[key] == null ||
          !incarnation_owners.exists(key) ||
          incarnation_owners[key] == null)
        continue;
      if (incarnation_handles[key].function_uid == handle.function_uid &&
          incarnation_handles[key].kind == handle.kind &&
          incarnation_handles[key].object_id == handle.object_id) begin
        owner = incarnation_owners[key];
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  // 功能：dependency_status 校验 owner、dependency、expected_kind、allow_null 与当前对象状态的一致性，并显式处理“required resource dependency is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：owner（输入）、dependency（输入）、expected_kind（输入）、allow_null（输入）；dependency_status 读取 owner、dependency、expected_kind、allow_null 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：dependency_status 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“required resource dependency is null”“resource dependency kind is invalid”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status dependency_status(
    rdma_function_handle owner,
    rdma_handle dependency,
    rdma_resource_kind_e expected_kind,
    bit allow_null
  );
    rdma_resource dependency_resource;
    rdma_status status;

    if (dependency == null) begin
      if (allow_null)
        return rdma_status::success();
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "required resource dependency is null");
    end
    if (dependency.kind != expected_kind)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource dependency kind is invalid");
    status = lookup(dependency, dependency_resource);
    if (!status.ok())
      return status;
    if (dependency_resource.state inside {RDMA_RESOURCE_QUIESCING,
                                          RDMA_RESOURCE_ERROR})
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "closing or failed dependency cannot admit new resources"
      );
    if (dependency_resource.owner == null ||
        !same_handle_instance(dependency_resource.owner, owner))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource dependency has another owner");
    return rdma_status::success();
  endfunction

  // 功能：resource_local_id 按 resource.kind 转换到对应资源对象，并返回该对象的 local_*_id；类型不匹配时由 UVM fatal 中止。
  // 输入/输出及副作用：resource（输入）；resource_local_id 读取 resource 并使用输入参数和固定枚举/常量；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：resource_local_id 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（Function resource type mismatch），不保留部分有效快照。
  protected function int unsigned resource_local_id(rdma_resource resource);
    rdma_pd pd;
    rdma_mr mr;
    rdma_cq cq;
    rdma_qp qp;
    rdma_srq srq;
    rdma_cmq cmq;
    rdma_ceq ceq;
    rdma_aeq aeq;
    rdma_function function_resource;

    case (resource.handle.kind)
      RDMA_RESOURCE_FUNCTION: begin
        if (!$cast(function_resource, resource))
          `uvm_fatal("RM_TYPE", "Function resource type mismatch")
        return function_resource.local_function_id;
      end
      RDMA_RESOURCE_PD: begin
        if (!$cast(pd, resource))
          `uvm_fatal("RM_TYPE", "PD resource type mismatch")
        return pd.local_pd_id;
      end
      RDMA_RESOURCE_MR: begin
        if (!$cast(mr, resource))
          `uvm_fatal("RM_TYPE", "MR resource type mismatch")
        return mr.local_mr_id;
      end
      RDMA_RESOURCE_CQ: begin
        if (!$cast(cq, resource))
          `uvm_fatal("RM_TYPE", "CQ resource type mismatch")
        return cq.local_cq_id;
      end
      RDMA_RESOURCE_QP: begin
        if (!$cast(qp, resource))
          `uvm_fatal("RM_TYPE", "QP resource type mismatch")
        return qp.local_qp_id;
      end
      RDMA_RESOURCE_SRQ: begin
        if (!$cast(srq, resource))
          `uvm_fatal("RM_TYPE", "SRQ resource type mismatch")
        return srq.local_srq_id;
      end
      RDMA_RESOURCE_CMQ: begin
        if (!$cast(cmq, resource))
          `uvm_fatal("RM_TYPE", "CMQ resource type mismatch")
        return cmq.local_cmq_id;
      end
      RDMA_RESOURCE_CEQ: begin
        if (!$cast(ceq, resource))
          `uvm_fatal("RM_TYPE", "CEQ resource type mismatch")
        return ceq.local_ceq_id;
      end
      RDMA_RESOURCE_AEQ: begin
        if (!$cast(aeq, resource))
          `uvm_fatal("RM_TYPE", "AEQ resource type mismatch")
        return aeq.local_aeq_id;
      end
    endcase
    `uvm_fatal("RM_KIND", "resource kind has no local ID pool")
    return '0;
  endfunction

// 功能：resource_depends_on 遍历 candidate.dependencies，按 handle 身份匹配 dependency，判断资源是否存在直接依赖；不修改运行时账本。
  // 输入/输出及副作用：candidate（输入）、dependency（输入）；resource_depends_on 读取 candidate、dependency 并使用字段 i；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：resource_depends_on 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function bit resource_depends_on(
    rdma_resource candidate,
    rdma_handle dependency
  );
    if (candidate == null || dependency == null)
      return 1'b0;
    foreach (candidate.dependencies[i]) begin
      if (candidate.dependencies[i] != null &&
          same_handle_instance(candidate.dependencies[i], dependency))
        return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：判断 has_dependents 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：resource（输入）；has_dependents 读取 resource 并使用字段 registry、key、kind、owner；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：has_dependents 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected function bit has_dependents(rdma_resource resource);
    foreach (registry[key]) begin
      if (registry[key] == resource)
        continue;
      if (resource_depends_on(registry[key], resource.handle))
        return 1'b1;
      if (resource.handle.kind == RDMA_RESOURCE_FUNCTION &&
          registry[key].owner != null &&
          same_handle_instance(registry[key].owner, resource.handle))
        return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：在 rdma_resource_manager 中读取指定资源的依赖与 outstanding 账本，生成供
  //   quiesce/finalize/release admission 共用的 detached blocker snapshot，并统计直接依赖
  //   与未完成操作数量，集中保持依赖优先的观察顺序。分类字段专门记录 QP/SRQ
  //   组合和 dependent 自身的 outstanding，供 CQ resize 等允许“空闲 QP 仍引用”的
  //   特殊策略复用同一次 registry 扫描。
  // 输入/输出及副作用：resource（输入）、snapshot（输出）；snapshot_activity_blockers 只读
  //   manager 自有 registry 和 resource.outstanding_ids，写入结构值，不更新 registry、不创建
  //   第二份账本，也不取得外部资源所有权；dependent 分类只依据已登记 handle.kind，
  //   不从业务字段推导 QP/SRQ 关系。
  // 失败/边界：resource 为 null 时 snapshot 全部字段为零；函数不替调用方 lookup、推导默认
  //   owner 或映射错误码，caller 必须在 registry schema 和句柄代际已验证后调用，并自行保持
  //   “依赖先于 outstanding”的既有错误优先级。
  protected function void snapshot_activity_blockers(
    rdma_resource resource,
    output rdma_resource_activity_blocker_snapshot snapshot
  );
    bit is_dependent;
    bit dependent_has_outstanding;
    rdma_resource_dependency_class_e dependent_class;

    snapshot = '{default: '0};
    if (resource == null)
      return;
    foreach (registry[key]) begin
      if (registry[key] == null || registry[key] == resource)
        continue;
      is_dependent = resource_depends_on(registry[key], resource.handle);
      if (resource.handle != null &&
          resource.handle.kind == RDMA_RESOURCE_FUNCTION &&
          registry[key].owner != null &&
          same_handle_instance(registry[key].owner, resource.handle))
        is_dependent = 1'b1;
      if (is_dependent)
        snapshot.dependent_count++;
      if (!is_dependent)
        continue;
      dependent_has_outstanding =
        registry[key].outstanding_ids.size() != 0;
      if (dependent_has_outstanding)
        snapshot.dependent_with_outstanding_count++;
      if (registry[key].handle == null)
        continue;
      dependent_class = rdma_resource_dependency_policy::classify(
        registry[key].handle.kind);
      case (dependent_class)
        RDMA_RESOURCE_DEP_QP: begin
          snapshot.qp_dependent_count++;
          snapshot.has_qp_dependents = 1'b1;
          if (dependent_has_outstanding)
            snapshot.has_qp_dependents_with_outstanding = 1'b1;
        end
        RDMA_RESOURCE_DEP_SRQ: begin
          snapshot.srq_dependent_count++;
          snapshot.has_srq_dependents = 1'b1;
          snapshot.has_non_qp_dependents = 1'b1;
        end
        default:
          snapshot.has_non_qp_dependents = 1'b1;
      endcase
    end
    snapshot.outstanding_count = resource.outstanding_ids.size();
    snapshot.has_live_dependents = snapshot.dependent_count != 0;
    snapshot.has_outstanding_operations = snapshot.outstanding_count != 0;
  endfunction

  // 设计：单资源 finalize 和 Function teardown 共用同一提交窗口。先检查整批 ID 再删除，
  // 避免第二个资源的 free-list 冲突使第一个资源已被释放。schema 规范化只替换等值快照，
  // 不推进业务 epoch；caller 必须在 admission/外部 completion 查询前冻结 epoch。
  // 功能：commit_resource_releases 原子提交已通过业务 admission 的有序释放集合，同时
  //   清除 recovery/staged、归还 local ID，并可将 Function generation 标记为 retired。
  // 输入/输出及副作用：keys 为按依赖顺序排列的 registry key，epoch_snapshot 为 admission
  //   前代际，operation 为诊断前缀；retire_generation 非空时与整批删除一起提交退休标志。
  //   只修改 manager 自有账本，保留 incarnation tombstone，不调用外部 adapter/clone。
  // 失败/边界：guard 忙、epoch 过期、key/handle 缺失或不一致、kind 非法、ID 越界、
  //   批内重复 ID 或 free-list 冲突均拒绝整批；空集合仅在需要退休 generation 时推进代际。
  //   caller 须先完成 schema 类型校验；损坏 carrier 的 cast 仍按 resource_local_id 报 fatal。
  protected function rdma_status commit_resource_releases(
    string keys[$],
    longint unsigned epoch_snapshot,
    string operation,
    string retire_generation = ""
  );
    rdma_resource_kind_e kinds[$];
    int unsigned local_ids[$];
    bit selected_ids[string];
    rdma_resource source;
    rdma_resource_kind_e kind;
    rdma_status status;
    int unsigned local_id;
    string local_key;

    if (mutation_guard == null || !mutation_guard.try_get(1))
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY, {operation, " release commit window is busy"}
      );
    status = rdma_status::success();
    if (epoch_snapshot != publication_epoch)
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE, {operation, " release admission is stale"}
      );
    foreach (keys[i]) begin
      if (!status.ok()) break;
      if (!registry.exists(keys[i]) || registry[keys[i]] == null ||
          registry[keys[i]].handle == null) begin
        status = rdma_status::make(
          RDMA_SC_INVALID_STATE, {operation, " release registry entry is missing"}
        );
        break;
      end
      source = registry[keys[i]];
      kind = source.handle.kind;
      if (!valid_kind(kind) || resource_key(source.handle) != keys[i]) begin
        status = rdma_status::make(
          RDMA_SC_INVALID_STATE, {operation, " release identity is inconsistent"}
        );
        break;
      end
      local_id = resource_local_id(source);
      if (local_id > local_id_limit(kind)) begin
        status = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          {operation, " authoritative local ID exceeds its hardware width"}
        );
        break;
      end
      local_key = $sformatf("%0d:%0d", kind, local_id);
      if (selected_ids.exists(local_key)) begin
        status = rdma_status::make(
          RDMA_SC_INVALID_STATE, {operation, " release set repeats a local ID"}
        );
        break;
      end
      foreach (free_local_ids[kind][j]) begin
        if (free_local_ids[kind][j] == local_id) begin
          status = rdma_status::make(
            RDMA_SC_INVALID_STATE,
            {operation, " authoritative local ID is already on the free list"}
          );
          break;
        end
      end
      selected_ids[local_key] = 1'b1;
      kinds.push_back(kind);
      local_ids.push_back(local_id);
    end
    // 此后只做本地赋值/删除，没有可能重入 manager 的外部调用或可失败校验。
    if (status.ok()) begin
      foreach (keys[i]) begin
        registry[keys[i]].state = RDMA_RESOURCE_RELEASED;
        free_local_ids[kinds[i]].push_back(local_ids[i]);
        recovery_records.delete(keys[i]);
        staged_allocations.delete(keys[i]);
        registry.delete(keys[i]);
      end
      if (retire_generation != "")
        retired_generations[retire_generation] = 1'b1;
      if (keys.size() != 0 || retire_generation != "")
        advance_publication_epoch();
    end
    mutation_guard.put(1);
    return status;
  endfunction

  // 功能：force_release_key 将单资源释放转换为统一释放集合，不在提交前重新采集代际，
  //   从而让外部 completion 查询期间的 mutation 仍能被最终 OCC 门禁识别。
  // 输入/输出及副作用：key 为已通过业务校验的资源，epoch_snapshot 来自 caller admission；
  //   成功后 manager 删除资源及恢复/暂存记录、回收 local ID；外部 backing 生命周期不变。
  // 失败/边界：未知 key、过期 epoch、重复/越界 ID 或 guard 忙原样返回，失败不写账本。
  protected function rdma_status force_release_key(
    string key,
    longint unsigned epoch_snapshot
  );
    string keys[$];

    keys.push_back(key);
    return commit_resource_releases(keys, epoch_snapshot, "release resource");
  endfunction

  // 功能：create_function 通过专用 Function identity candidate 预留 generation owner、
  //   local ID 和 binding registration，构造 Function authority 并登记发布 detached resource。
  // 输入/输出及副作用：binding（输入）提供 Function/generation authority；function_resource
  //   （输出）接收发布后的 Function 快照；失败时 candidate 负责恢复未发布的 allocator/binding
  //   预留，不转移外部 binding 所有权。
  // 失败/边界：空/过期/重复 binding、旧 generation 仍存活、tombstone 已存在、local-ID
  //   exhausted、字段投影或 register_resource 失败均原样返回并回滚；published Function 类型
  //   不匹配仍触发 UVM fatal（published Function type mismatch）。
  function rdma_status create_function(
    rdma_function_binding binding,
    output rdma_function function_resource
  );
    rdma_status status;
    rdma_function_identity_candidate identity;
    rdma_function authoritative;
    rdma_resource published;

    function_resource = null;
    status = reserve_function_identity_candidate(binding, identity);
    if (!status.ok())
      return status;
    authoritative = new("function_resource");
    authoritative.handle = identity.handle;
    status = project_function_handle_value(identity.owner, "Function owner",
                                           authoritative.owner);
    if (!status.ok()) begin
      rollback_function_identity_candidate(identity);
      return status;
    end
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_function_id = identity.local_id;
    authoritative.global_function_id = identity.owner.object_id;
    authoritative.rdma_vf_id = identity.trusted_binding.rdma_vf_id;
    authoritative.vsi_id = identity.trusted_binding.vsi_id;
    authoritative.pfvf_id = identity.trusted_binding.pfvf_id;
    // rdma_function::new creates its default binding through the factory.
    // Replace it explicitly before any manager clone or validation dispatch.
    authoritative.binding = null;
    status = project_binding_value(identity.trusted_binding, "Function resource",
                                   authoritative.binding);
    if (!status.ok()) begin
      rollback_function_identity_candidate(identity);
      return status;
    end
    status = publish_function_identity_candidate(identity, authoritative,
                                                 published);
    if (!status.ok()) begin
      rollback_function_identity_candidate(identity);
      return status;
    end
    if (!$cast(function_resource, published))
      `uvm_fatal("RM_COPY_TYPE", "published Function type mismatch")
    identity.clear();
    return rdma_status::success();
  endfunction

  // 功能：create_pd 创建独立的 rdma_status；根据 binding、pd 设置字段 pd、status、authoritative、authoritative.handle、authoritative.owner、authoritative.state、authoritative.local_pd_id、authoritative.global_pd_id，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、pd（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：create_pd 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（published PD type mismatch），不保留部分有效快照。
  function rdma_status create_pd(
    rdma_function_binding binding,
    output rdma_pd pd
  );
    rdma_status status;
    rdma_resource_identity_candidate identity;
    rdma_pd authoritative;
    rdma_resource published;

    pd = null;
    status = reserve_identity_candidate(binding, RDMA_RESOURCE_PD, identity);
    if (!status.ok())
      return status;
    authoritative = new("pd");
    authoritative.handle = identity.handle;
    authoritative.owner = identity.owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_pd_id = identity.local_id;
    authoritative.global_pd_id = identity.handle.object_id;
    status = publish_identity_candidate(identity, authoritative,
                                        "create PD", published);
    if (!status.ok())
      return status;
    if (!$cast(pd, published))
      `uvm_fatal("RM_COPY_TYPE", "published PD type mismatch")
    return rdma_status::success();
  endfunction

  // 功能：create_mr 校验 active Function 和同 owner PD，预留 MR identity 并发布 ALLOCATED
  //   reservation；lkey 高 24 位保存 local index，低 8 位保持零，尚未申请硬件 key。
  // 输入/输出及副作用：binding、pd_h 为输入，mr 接收 detached 资源；成功更新 allocator/
  //   registry/incarnation，登记 PD dependency，不分配 DMA backing 或编程 MPT。
  // 失败/边界：binding/PD 无效或 closing、代际过期、ID 耗尽、投影/publication 失败均返回
  //   错误并回滚预留，mr=null；published carrier 类型不符仍报 RM_COPY_TYPE fatal。
  function rdma_status create_mr(
    rdma_function_binding binding,
    rdma_handle pd_h,
    output rdma_mr mr
  );
    rdma_status status;
    rdma_resource_identity_candidate identity;
    rdma_mr authoritative;
    rdma_resource published;
    rdma_handle dependency_copy;
    rdma_function_handle owner;

    mr = null;
    status = active_binding_status(binding, owner);
    if (!status.ok())
      return status;
    status = dependency_status(owner, pd_h, RDMA_RESOURCE_PD, 1'b0);
    if (!status.ok())
      return status;
    status = reserve_identity_candidate(binding, RDMA_RESOURCE_MR, identity);
    if (!status.ok())
      return status;
    authoritative = new("mr");
    authoritative.handle = identity.handle;
    authoritative.owner = identity.owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_mr_id = identity.local_id;
    authoritative.global_mr_id = identity.handle.object_id;
    // reservation 已拥有 local index，但尚未申请 hardware key byte。先保留 index、
    // 将低 8 位 key 置零，使未 staged 的非零 ID MR 也能发布本地 ERROR cleanup。
    // 该值不是可用 MPT key：ALLOCATED/ERROR 均不能承载数据面访问，stage 仍须提供正式 key。
    authoritative.lkey = {identity.local_id[23:0], 8'h00};
    status = project_handle_value(pd_h, "MR PD", authoritative.pd_h);
    if (status.ok())
      status = project_handle_value(pd_h, "MR dependency", dependency_copy);
    if (!status.ok()) begin
      rollback_identity_candidate(identity);
      return status;
    end
    authoritative.dependencies.push_back(dependency_copy);
    status = publish_identity_candidate(identity, authoritative,
                                        "create MR", published);
    if (!status.ok())
      return status;
    if (!$cast(mr, published))
      `uvm_fatal("RM_COPY_TYPE", "published MR type mismatch")
    return rdma_status::success();
  endfunction

  // 功能：create_cq 创建独立的 rdma_status；根据 binding、ceq_h、cq 设置字段 cq、status、authoritative、authoritative.handle、authoritative.owner、authoritative.state、authoritative.local_cq_id、authoritative.global_cq_id，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、ceq_h（输入）、cq（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：create_cq 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（published CQ type mismatch），不保留部分有效快照。
  function rdma_status create_cq(
    rdma_function_binding binding,
    rdma_handle ceq_h,
    output rdma_cq cq
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_resource_identity_candidate identity;
    rdma_cq authoritative;
    rdma_resource published;
    rdma_handle dependency_copy;

    cq = null;
    status = active_binding_status(binding, owner);
    if (!status.ok())
      return status;
    status = dependency_status(owner, ceq_h, RDMA_RESOURCE_CEQ, 1'b1);
    if (!status.ok())
      return status;
    status = reserve_identity_candidate(binding, RDMA_RESOURCE_CQ, identity);
    if (!status.ok())
      return status;
    authoritative = new("cq");
    authoritative.handle = identity.handle;
    authoritative.owner = identity.owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_cq_id = identity.local_id;
    authoritative.global_cq_id = identity.handle.object_id;
    if (ceq_h != null) begin
      status = project_handle_value(ceq_h, "CQ CEQ", authoritative.ceq_h);
      if (status.ok())
        status = project_handle_value(ceq_h, "CQ dependency",
                                   dependency_copy);
      if (!status.ok()) begin
        rollback_identity_candidate(identity);
        return status;
      end
      authoritative.dependencies.push_back(dependency_copy);
    end
    status = publish_identity_candidate(identity, authoritative,
                                        "create CQ", published);
    if (!status.ok())
      return status;
    if (!$cast(cq, published))
      `uvm_fatal("RM_COPY_TYPE", "published CQ type mismatch")
    return rdma_status::success();
  endfunction

  // 功能：create_qp 创建独立的 rdma_status；根据 binding、pd_h、send_cq_h、recv_cq_h、srq_h、qp 设置字段 qp、status、authoritative、authoritative.handle、authoritative.owner、authoritative.state、authoritative.local_qp_id、authoritative.global_qp_id、sequence_key，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、pd_h（输入）、send_cq_h（输入）、recv_cq_h（输入）、srq_h（输入）、qp（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output
  //   发布新句柄/映射。
  // 失败/边界：create_qp 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（published QP type mismatch），不保留部分有效快照。
  function rdma_status create_qp(
    rdma_function_binding binding,
    rdma_handle pd_h,
    rdma_handle send_cq_h,
    rdma_handle recv_cq_h,
    rdma_handle srq_h,
    output rdma_qp qp
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_resource_identity_candidate identity;
    rdma_qp authoritative;
    rdma_resource published;
    rdma_handle dependency_copy;
    string sequence_key;

    qp = null;
    status = active_binding_status(binding, owner);
    if (!status.ok())
      return status;
    status = dependency_status(owner, pd_h, RDMA_RESOURCE_PD, 1'b0);
    if (!status.ok())
      return status;
    status = dependency_status(owner, send_cq_h, RDMA_RESOURCE_CQ, 1'b0);
    if (!status.ok())
      return status;
    status = dependency_status(owner, recv_cq_h, RDMA_RESOURCE_CQ, 1'b0);
    if (!status.ok())
      return status;
    status = dependency_status(owner, srq_h, RDMA_RESOURCE_SRQ, 1'b1);
    if (!status.ok())
      return status;
    status = reserve_identity_candidate(binding, RDMA_RESOURCE_QP, identity);
    if (!status.ok())
      return status;
    authoritative = new("qp");
    authoritative.handle = identity.handle;
    authoritative.owner = identity.owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_qp_id = identity.local_id;
    authoritative.global_qp_id = identity.handle.object_id;
    status = project_handle_value(pd_h, "QP PD", authoritative.pd_h);
    if (status.ok())
      status = project_handle_value(send_cq_h, "QP send CQ",
                                 authoritative.send_cq_h);
    if (status.ok())
      status = project_handle_value(recv_cq_h, "QP receive CQ",
                                 authoritative.recv_cq_h);
    if (status.ok())
      status = project_handle_value(pd_h, "QP PD dependency", dependency_copy);
    if (status.ok()) begin
      authoritative.dependencies.push_back(dependency_copy);
      status = project_handle_value(send_cq_h, "QP send CQ dependency",
                                 dependency_copy);
    end
    if (status.ok()) begin
      authoritative.dependencies.push_back(dependency_copy);
      status = project_handle_value(recv_cq_h, "QP receive CQ dependency",
                                 dependency_copy);
    end
    if (status.ok())
      authoritative.dependencies.push_back(dependency_copy);
    if (!status.ok()) begin
      rollback_identity_candidate(identity);
      return status;
    end
    if (srq_h != null) begin
      status = project_handle_value(srq_h, "QP SRQ", authoritative.srq_h);
      if (status.ok())
        status = project_handle_value(srq_h, "QP SRQ dependency",
                                   dependency_copy);
      if (!status.ok()) begin
        rollback_identity_candidate(identity);
        return status;
      end
      authoritative.dependencies.push_back(dependency_copy);
    end
    status = publish_identity_candidate(identity, authoritative,
                                        "create QP", published);
    if (!status.ok())
      return status;
    if (!$cast(qp, published))
      `uvm_fatal("RM_COPY_TYPE", "published QP type mismatch")
    sequence_key = qp_sequence_key(authoritative.owner, authoritative.local_qp_id);
    if (qp_sequences.exists(sequence_key))
      qp_sequences[sequence_key]++;
    else
      qp_sequences[sequence_key] = '0;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，qp_sequence 查询或更新指定 QP 的 incarnation sequence，保证 object ID 复用时 generation 单调推进。
  // 输入/输出及副作用：owner（输入）、local_qpn（输入）、sequence_value（输出）；qp_sequence 读取 owner、local_qpn、sequence_value 并使用字段 sequence_value、status、key，并写入 sequence_value；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：qp_sequence 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“QP sequence identity is invalid”“QP sequence identity is unknown”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status qp_sequence(
    rdma_function_handle owner,
    int unsigned local_qpn,
    output bit [7:0] sequence_value
  );
    rdma_function_handle trusted_owner;
    rdma_status status;
    string key;

    sequence_value = '0;
    status = project_function_handle_value(owner, "QP sequence owner",
                                           trusted_owner);
    if (!status.ok())
      return status;
    if (trusted_owner == null ||
        trusted_owner.kind != RDMA_RESOURCE_FUNCTION ||
        local_qpn > local_id_limit(RDMA_RESOURCE_QP))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP sequence identity is invalid");
    status = owner_binding_status(trusted_owner);
    if (!status.ok())
      return status;
    key = qp_sequence_key(trusted_owner, local_qpn);
    if (!qp_sequences.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP sequence identity is unknown");
    sequence_value = qp_sequences[key];
    return rdma_status::success();
  endfunction

  // 功能：create_srq 创建独立的 rdma_status；根据 binding、pd_h、srq 设置字段 srq、status、authoritative、authoritative.handle、authoritative.owner、authoritative.state、authoritative.local_srq_id、authoritative.global_srq_id，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、pd_h（输入）、srq（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：create_srq 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（published SRQ type mismatch），不保留部分有效快照。
  function rdma_status create_srq(
    rdma_function_binding binding,
    rdma_handle pd_h,
    output rdma_srq srq
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_resource_identity_candidate identity;
    rdma_srq authoritative;
    rdma_resource published;
    rdma_handle dependency_copy;

    srq = null;
    status = active_binding_status(binding, owner);
    if (!status.ok())
      return status;
    status = dependency_status(owner, pd_h, RDMA_RESOURCE_PD, 1'b0);
    if (!status.ok())
      return status;
    status = reserve_identity_candidate(binding, RDMA_RESOURCE_SRQ, identity);
    if (!status.ok())
      return status;
    authoritative = new("srq");
    authoritative.handle = identity.handle;
    authoritative.owner = identity.owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_srq_id = identity.local_id;
    authoritative.global_srq_id = identity.handle.object_id;
    status = project_handle_value(pd_h, "SRQ PD", authoritative.pd_h);
    if (status.ok())
      status = project_handle_value(pd_h, "SRQ dependency", dependency_copy);
    if (!status.ok()) begin
      rollback_identity_candidate(identity);
      return status;
    end
    authoritative.dependencies.push_back(dependency_copy);
    status = publish_identity_candidate(identity, authoritative,
                                        "create SRQ", published);
    if (!status.ok())
      return status;
    if (!$cast(srq, published))
      `uvm_fatal("RM_COPY_TYPE", "published SRQ type mismatch")
    return rdma_status::success();
  endfunction

  // 功能：create_cmq 创建独立的 rdma_status；根据 binding、cmq 设置字段 cmq、status、authoritative、authoritative.handle、authoritative.owner、authoritative.state、authoritative.local_cmq_id、authoritative.global_cmq_id，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、cmq（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：create_cmq 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（published CMQ type mismatch），不保留部分有效快照。
  function rdma_status create_cmq(
    rdma_function_binding binding,
    output rdma_cmq cmq
  );
    rdma_status status;
    rdma_resource_identity_candidate identity;
    rdma_cmq authoritative;
    rdma_resource published;

    cmq = null;
    status = reserve_identity_candidate(binding, RDMA_RESOURCE_CMQ, identity);
    if (!status.ok())
      return status;
    authoritative = new("cmq");
    authoritative.handle = identity.handle;
    authoritative.owner = identity.owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_cmq_id = identity.local_id;
    authoritative.global_cmq_id = identity.handle.object_id;
    status = publish_identity_candidate(identity, authoritative,
                                        "create CMQ", published);
    if (!status.ok())
      return status;
    if (!$cast(cmq, published))
      `uvm_fatal("RM_COPY_TYPE", "published CMQ type mismatch")
    return rdma_status::success();
  endfunction

  // 功能：create_ceq 创建独立的 rdma_status；根据 binding、ceq 设置字段 ceq、status、authoritative、authoritative.handle、authoritative.owner、authoritative.state、authoritative.local_ceq_id、authoritative.global_ceq_id，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、ceq（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：create_ceq 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（published CEQ type mismatch），不保留部分有效快照。
  function rdma_status create_ceq(
    rdma_function_binding binding,
    output rdma_ceq ceq
  );
    rdma_status status;
    rdma_resource_identity_candidate identity;
    rdma_ceq authoritative;
    rdma_resource published;

    ceq = null;
    status = reserve_identity_candidate(binding, RDMA_RESOURCE_CEQ, identity);
    if (!status.ok())
      return status;
    authoritative = new("ceq");
    authoritative.handle = identity.handle;
    authoritative.owner = identity.owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_ceq_id = identity.local_id;
    authoritative.global_ceq_id = identity.handle.object_id;
    status = publish_identity_candidate(identity, authoritative,
                                        "create CEQ", published);
    if (!status.ok())
      return status;
    if (!$cast(ceq, published))
      `uvm_fatal("RM_COPY_TYPE", "published CEQ type mismatch")
    return rdma_status::success();
  endfunction

  // 功能：create_aeq 创建独立的 rdma_status；根据 binding、aeq 设置字段 aeq、status、authoritative、authoritative.handle、authoritative.owner、authoritative.state、authoritative.local_aeq_id、authoritative.global_aeq_id，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、aeq（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：create_aeq 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（published AEQ type mismatch），不保留部分有效快照。
  function rdma_status create_aeq(
    rdma_function_binding binding,
    output rdma_aeq aeq
  );
    rdma_status status;
    rdma_resource_identity_candidate identity;
    rdma_aeq authoritative;
    rdma_resource published;

    aeq = null;
    status = reserve_identity_candidate(binding, RDMA_RESOURCE_AEQ, identity);
    if (!status.ok())
      return status;
    authoritative = new("aeq");
    authoritative.handle = identity.handle;
    authoritative.owner = identity.owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_aeq_id = identity.local_id;
    authoritative.global_aeq_id = identity.handle.object_id;
    status = publish_identity_candidate(identity, authoritative,
                                        "create AEQ", published);
    if (!status.ok())
      return status;
    if (!$cast(aeq, published))
      `uvm_fatal("RM_COPY_TYPE", "published AEQ type mismatch")
    return rdma_status::success();
  endfunction

  // 功能：lookup 按完整 incarnation 查找 registry，检查 owner binding 后返回 detached 资源，
  //   不把查询投影重新写回 registry，防止重入查询覆盖已提交状态。
  // 输入/输出及副作用：handle 为非拥有查找键，resource 成功时接收双层投影快照；
  //   generation observer 可刷新 high-water，但不更新 registry/recovery 或外部 backing。
  // 失败/边界：空/畸形/未知/已释放 handle、过期 binding、投影失败或投影期间 epoch/source
  //   改变时返回错误且 resource=null；保留旧 generation 优先于 released 的诊断顺序。
  function rdma_status lookup(
    rdma_handle handle,
    output rdma_resource resource
  );
    string key;
    string incarnation;
    rdma_resource authoritative;
    rdma_function_handle owner;
    rdma_handle trusted_handle;
    rdma_status status;
    rdma_resource source_resource;
    rdma_resource detached;
    longint unsigned epoch_snapshot;

    resource = null;
    status = project_handle_value(handle, "lookup", trusted_handle);
    if (!status.ok())
      return status;
    if (trusted_handle == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource handle is null");
    if (!valid_kind(trusted_handle.kind))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource handle kind is invalid");
    if (trusted_handle.kind != RDMA_RESOURCE_FUNCTION &&
        trusted_handle.object_id[31:28] != trusted_handle.kind)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource incarnation kind prefix is invalid");

    key = resource_key(trusted_handle);
    if (registry.exists(key)) begin
      source_resource = registry[key];
      epoch_snapshot = publication_epoch;
      status = project_resource_value(source_resource, "lookup registry entry",
                                      authoritative);
      if (!status.ok())
        return status;
      if (authoritative.handle == null ||
          !same_handle_instance(authoritative.handle, trusted_handle))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "registry identity is inconsistent");
      status = owner_binding_status(authoritative.owner);
      if (!status.ok())
        return status;
      status = project_resource_value(authoritative, "lookup", detached);
      if (!status.ok())
        return status;
      if (epoch_snapshot != publication_epoch || !registry.exists(key) ||
          registry[key] != source_resource)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE, "lookup authority changed during projection"
        );
      resource = detached;
      return rdma_status::success();
    end

    incarnation = incarnation_key(trusted_handle);
    if (!incarnation_owners.exists(incarnation)) begin
      if (related_incarnation_owner(trusted_handle, owner))
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "resource handle generation is stale");
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource handle is unknown or forged");
    end
    owner = incarnation_owners[incarnation];
    status = owner_binding_status(owner);
    if (status.code == RDMA_SC_STALE_GENERATION)
      return status;
    if (!status.ok())
      return status;
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "resource handle has been released");
  endfunction

  // 设计说明：local-resource lookup 的 registry 遍历只负责观察 owner、generation、
  // local-id 和生命周期状态；project_resource_value 会触发 factory/快照复制，不能
  // 在“多个 live 命中”的歧义分支中提前执行。把只读匹配与 detached 投影分开，既
  // 保留 generation 优先级，也让 caller 在确认唯一 live candidate 后才发布 resource。
  // 功能：scan_local_resource_matches 按 trusted_owner、kind 和完整 local_id 扫描
  //   registry，收集唯一 live candidate 以及 stale/released/multiple 状态证据。
  // 输入/输出及副作用：trusted_owner、kind、local_id 为已完成前置校验的输入；
  //   live_candidate、found_live、found_released、found_stale、multiple_live 为输出。
  //   helper 只读取 registry 和 resource 字段，不创建 rdma_status、不投影快照、不改写
  //   registry，也不取得任何 resource 或外部 backing 的所有权。
  // 失败/边界：null/错误 kind、owner 或越界 local_id 由 caller 处理；匹配到旧 generation
  //   只置 found_stale，RELEASED 只对同一 local_id 置 found_released，NEW/ERROR 跳过；
  //   第二个 live 命中置 multiple_live 并停止扫描，caller 必须在投影前返回歧义错误。
  protected function void scan_local_resource_matches(
    rdma_function_handle trusted_owner,
    rdma_resource_kind_e kind,
    int unsigned local_id,
    output rdma_resource live_candidate,
    output bit found_live,
    output bit found_released,
    output bit found_stale,
    output bit multiple_live
  );
    rdma_resource candidate;
    int unsigned candidate_local_id;

    live_candidate = null;
    found_live = 1'b0;
    found_released = 1'b0;
    found_stale = 1'b0;
    multiple_live = 1'b0;

    foreach (registry[key]) begin
      candidate = registry[key];
      if (candidate == null || candidate.handle == null ||
          candidate.handle.kind != kind || candidate.owner == null)
        continue;

      if (candidate.owner.function_uid != trusted_owner.function_uid ||
          candidate.owner.object_id != trusted_owner.object_id)
        continue;

      if (candidate.owner.generation != trusted_owner.generation) begin
        found_stale = 1'b1;
        continue;
      end

      candidate_local_id = resource_local_id(candidate);
      if (candidate_local_id != local_id)
        continue;

      if (candidate.state == RDMA_RESOURCE_RELEASED) begin
        found_released = 1'b1;
        continue;
      end
      if (candidate.state inside {RDMA_RESOURCE_NEW, RDMA_RESOURCE_ERROR})
        continue;
      if (found_live) begin
        multiple_live = 1'b1;
        return;
      end

      live_candidate = candidate;
      found_live = 1'b1;
    end
  endfunction

  // 功能：lookup_local_resource 按当前 Function owner、资源 kind 和完整 local_id
  //   反查唯一权威资源，供 AEQE/CEQE 等 wire owner route 使用。
  // 输入/输出及副作用：owner、kind、local_id 为输入，resource 为 detached 输出；
  //   函数只读取 binding/registry，成功时复制资源快照，不修改资源状态或取得外部
  //   backing 所有权，也不把 wire ID 截断后再查询。
  // 失败/边界：owner 为空、generation 非当前、kind 不支持、local_id 超出该 kind
  //   硬件宽度、无匹配、匹配资源已 RELEASED、发现多个 live 匹配或发现旧 generation
  //   记录时返回明确错误；不同 Function UID、Function object 或 generation 的资源
  //   永远不会被当作命中。
  function rdma_status lookup_local_resource(
    rdma_function_handle owner,
    rdma_resource_kind_e kind,
    int unsigned local_id,
    output rdma_resource resource
  );
    rdma_function_handle trusted_owner;
    rdma_resource live_candidate;
    rdma_resource projected;
    rdma_status status;
    bit found_live;
    bit found_released;
    bit found_stale;
    bit multiple_live;

    resource = null;

    status = project_function_handle_value(
      owner, "lookup local resource owner", trusted_owner
    );
    if (status == null || !status.ok() || trusted_owner == null)
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "lookup local resource owner is invalid"
      ) : status;

    if (!valid_kind(kind) || kind == RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "lookup local resource kind is invalid"
      );
    if (local_id > local_id_limit(kind))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "lookup local resource ID exceeds hardware width"
      );

    status = owner_binding_status(trusted_owner);
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "lookup local resource owner status is unavailable"
      ) : status;

    scan_local_resource_matches(
      trusted_owner, kind, local_id, live_candidate, found_live,
      found_released, found_stale, multiple_live
    );

    if (multiple_live)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "lookup local resource found multiple live matches"
      );

    if (found_live) begin
      status = project_resource_value(
        live_candidate, "lookup local resource", projected
      );
      if (status == null || !status.ok() || projected == null)
        return status == null ? rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "lookup local resource projection failed"
        ) : status;
      resource = projected;
    end

    if (found_live)
      return rdma_status::success();
    if (found_stale)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "lookup local resource found stale generation"
      );
    if (found_released)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "lookup local resource has been released"
      );
    return rdma_status::make(
      RDMA_SC_INVALID_ARGUMENT,
      "lookup local resource is unknown"
    );
  endfunction

  // 功能：stage_allocated 校验普通资源可编程性，将 detached 候选保留为 ALLOCATED 并标记 staged。
  // 输入/输出及副作用：candidate 提供资源值；成功原子替换 registry/暂存标志并推进 epoch，
  //   不分配新的 ID 或取得 backing 所有权；PD 不需要 PROGRAMMED 预检。
  // 失败/边界：QP、非 ALLOCATED、identity/投影/validate 失败、epoch/source 改变或锁忙
  //   均拒绝；原 resource 与 staged 标志保持，不在外部回调后重新采样 epoch。
  virtual function rdma_status stage_allocated(rdma_resource candidate);
    rdma_resource authoritative;
    rdma_resource prepared;
    rdma_resource replacement;
    rdma_status status;
    rdma_resource source_resource;
    longint unsigned epoch_snapshot;
    string key;

    epoch_snapshot = publication_epoch;
    status = project_public_resource_value(candidate, "stage allocated",
                                           replacement);
    if (!status.ok())
      return status;
    if (replacement.handle.kind == RDMA_RESOURCE_QP)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP resources require QP-specific programming attachment"
      );
    if (replacement.state != RDMA_RESOURCE_ALLOCATED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "staged candidate must be ALLOCATED");
    status = lookup(replacement.handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    source_resource = registry[key];
    if (registry[key].state != RDMA_RESOURCE_ALLOCATED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "registry resource is not ALLOCATED");
    status = publication_identity_status(replacement, authoritative);
    if (!status.ok())
      return status;
    if (replacement.handle.kind != RDMA_RESOURCE_PD) begin
      status = project_public_resource_value(replacement, "stage prepared",
                                           prepared);
      if (!status.ok())
        return status;
      prepared.state = RDMA_RESOURCE_PROGRAMMED;
      status = prepared.validate();
      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "prepared staged candidate validation returned null"
        );
      if (!status.ok())
        return status;
    end
    replacement.state = RDMA_RESOURCE_ALLOCATED;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "staged candidate validation returned null");
    if (!status.ok())
      return status;
    return commit_registry_replacement(
      key, replacement, "stage allocated", epoch_snapshot, source_resource, 1'b1
    );
  endfunction

  // 功能：attach_cq_programming 将已构造并校验的 CQC context 绑定到
  // ALLOCATED/staged CQ authority，使成功、歧义和恢复路径共享 typed snapshot。
  // 输入/输出及副作用：candidate 必须携带 CQ handle、queue plan 和
  // programmed_cqc；通过身份、generation、状态和 CQC 校验后替换 manager
  // registry 的 detached CQ 快照，并保留 staged_allocations 标记。
  // 失败/边界：candidate 为空、类型/状态错误、缺少 CQC、CQC 身份不匹配、
  // validate 失败、registry 非 staged ALLOCATED、已有 CQC 或 publication
  // identity、入口 epoch 或查表后的 source 改变以及锁忙时返回错误，失败不修改 registry。
  virtual function rdma_status attach_cq_programming(rdma_cq candidate);
    rdma_resource authoritative;
    rdma_resource projected;
    rdma_cq replacement;
    rdma_cq authoritative_cq;
    rdma_cqc_model cqc;
    rdma_status status;
    rdma_resource source_resource;
    longint unsigned epoch_snapshot;
    string key;

    epoch_snapshot = publication_epoch;
    if (candidate == null || candidate.handle == null ||
        candidate.handle.kind != RDMA_RESOURCE_CQ)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CQ programming candidate is invalid"
      );
    if (candidate.state != RDMA_RESOURCE_ALLOCATED ||
        candidate.programmed_cqc == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CQ programming requires an ALLOCATED candidate with CQC"
      );

    status = project_public_resource_value(
      candidate, "attach CQ programming", projected
    );
    if (!status.ok() || !$cast(replacement, projected))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CQ programming candidate projection failed"
      ) : status;

    if (!$cast(cqc, replacement.programmed_cqc) || cqc == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CQ programming candidate CQC type is invalid"
      );
    status = cqc.validate();
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CQ programming candidate CQC validation returned null"
      ) : status;
    if (cqc.cq_h == null ||
        cqc.cq_h.kind != RDMA_RESOURCE_CQ ||
        cqc.cq_h.object_id != replacement.local_cq_id ||
        cqc.cq_h.function_uid != replacement.handle.function_uid ||
        cqc.cq_h.generation != replacement.handle.generation)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "CQ programming candidate CQC identity does not match"
      );

    status = lookup(replacement.handle, authoritative);
    if (!status.ok())
      return status;
    if (!$cast(authoritative_cq, authoritative) || authoritative_cq == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CQ programming target type is invalid"
      );

    key = resource_key(authoritative.handle);
    source_resource = registry[key];
    if (!registry.exists(key) || registry[key] == null ||
        registry[key].state != RDMA_RESOURCE_ALLOCATED ||
        !staged_allocations.exists(key))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CQ programming target is not a staged ALLOCATED resource"
      );
    if (authoritative_cq.programmed_cqc != null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CQ programming target already has a CQC"
      );

    status = publication_identity_status(replacement, authoritative);
    if (!status.ok())
      return status;
    status = replacement.validate();
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "CQ programming replacement validation returned null"
      ) : status;

    return commit_registry_replacement(
      key, replacement, "attach CQ programming", epoch_snapshot, source_resource
    );
  endfunction

  // 功能：commit_programmed 将已 staged 的普通资源从 ALLOCATED 发布为 PROGRAMMED。
  // 输入/输出及副作用：candidate 为 detached 编程结果；成功更新 registry、清除 staged 并
  //   推进一次 epoch，不执行硬件命令、不改变外部 backing 生命周期。
  // 失败/边界：QP/PD、候选或 authority 非 ALLOCATED、未 staged、identity/validate 失败、
  //   入口 epoch/source 冲突或锁忙时拒绝，保留原资源和暂存证据。
  virtual function rdma_status commit_programmed(rdma_resource candidate);
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_status status;
    rdma_resource source_resource;
    longint unsigned epoch_snapshot;
    string key;

    epoch_snapshot = publication_epoch;
    status = project_public_resource_value(candidate, "commit programmed",
                                           replacement);
    if (!status.ok())
      return status;
    if (replacement.handle.kind == RDMA_RESOURCE_QP)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP resources require QP-specific programmed commit"
      );
    if (replacement.state != RDMA_RESOURCE_ALLOCATED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "programmed candidate must be ALLOCATED");
    status = lookup(replacement.handle, authoritative);
    if (!status.ok())
      return status;
    if (authoritative.handle.kind == RDMA_RESOURCE_PD)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "PD transitions directly from ALLOCATED to ACTIVE"
      );
    key = resource_key(authoritative.handle);
    source_resource = registry[key];
    if (registry[key].state != RDMA_RESOURCE_ALLOCATED ||
        !staged_allocations.exists(key))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "only a staged ALLOCATED resource can be programmed"
      );
    status = publication_identity_status(replacement, authoritative);
    if (!status.ok())
      return status;
    replacement.state = RDMA_RESOURCE_PROGRAMMED;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "programmed candidate validation returned null"
      );
    if (!status.ok())
      return status;
    return commit_registry_replacement(
      key, replacement, "commit programmed", epoch_snapshot, source_resource,
      1'b0, 1'b1
    );
  endfunction

  // 功能：activate 将 PD 的 ALLOCATED 或其它资源的 PROGRAMMED 快照发布为 ACTIVE。
  // 输入/输出及副作用：handle 定位 authority；成功替换 detached resource、清 staged 并推进
  //   epoch，不绑定或接管外部 adapter。
  // 失败/边界：lookup 失败、来源状态不符（包括重复激活）、投影/validate 失败、入口 epoch
  //   或 source 改变、锁忙时不激活资源且保留 staged。
  virtual function rdma_status activate(rdma_handle handle);
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_status status;
    rdma_resource source_resource;
    longint unsigned epoch_snapshot;
    string key;

    epoch_snapshot = publication_epoch;
    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    source_resource = registry[key];
    if (authoritative.handle.kind == RDMA_RESOURCE_PD) begin
      if (registry[key].state != RDMA_RESOURCE_ALLOCATED)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "PD activation requires ALLOCATED state"
        );
    end
    else if (registry[key].state != RDMA_RESOURCE_PROGRAMMED) begin
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "non-PD activation requires PROGRAMMED state"
      );
    end
    status = project_resource_value(registry[key], "activate", replacement);
    if (!status.ok())
      return status;
    replacement.state = RDMA_RESOURCE_ACTIVE;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "active resource validation returned null");
    if (!status.ok())
      return status;
    return commit_registry_replacement(
      key, replacement, "activate", epoch_snapshot, source_resource, 1'b0, 1'b1
    );
  endfunction

  // 功能：在 rdma_resource_manager 中，begin_quiesce 校验资源代际并通过 blocker snapshot
  //   读取依赖/outstanding 活动后，把活动对象切换到 quiescing，阻止新的提交并为销毁/复位建立屏障。
  // 输入/输出及副作用：handle（输入）；begin_quiesce 读取 handle 并使用字段 status、key、replacement.state；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：begin_quiesce 返回 RDMA_SC_INVALID_STATE、RDMA_SC_RESOURCE_BUSY；典型拒绝
  //   条件为“only ACTIVE resource can begin quiesce”“resource still has live dependents”
  //   “resource still has outstanding operations”，并保持依赖先于 outstanding 的错误优先级；
  //   schema/投影失败、入口 epoch/source 冲突或锁忙同样拒绝，不提交部分生命周期状态。
  virtual function rdma_status begin_quiesce(rdma_handle handle);
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_status status;
    rdma_resource_activity_blocker_snapshot blockers;
    rdma_resource source_resource;
    longint unsigned epoch_snapshot;
    string key;

    epoch_snapshot = publication_epoch;
    status = registry_schema_status("begin quiesce");
    if (!status.ok())
      return status;
    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    source_resource = registry[key];
    if (registry[key].state != RDMA_RESOURCE_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "only ACTIVE resource can begin quiesce");
    snapshot_activity_blockers(registry[key], blockers);
    if (blockers.has_live_dependents)
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "resource still has live dependents");
    if (blockers.has_outstanding_operations)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "resource still has outstanding operations"
      );
    status = project_resource_value(registry[key], "begin quiesce",
                                    replacement);
    if (!status.ok())
      return status;
    replacement.state = RDMA_RESOURCE_QUIESCING;
    return commit_registry_replacement(
      key, replacement, "begin quiesce", epoch_snapshot, source_resource
    );
  endfunction

  // 功能：begin_cq_resize 为 CQ backing replacement 建立专用 quiesce 屏障；允许仍被空闲 QP 引用的 CQ 进入 QUIESCING，同时保留完整依赖拓扑。
  // 输入/输出及副作用：handle（输入）；begin_cq_resize 读取 CQ authority、依赖资源和 outstanding_ids，并原子更新 registry 中 CQ 的 state；函数返回 rdma_status，不接管外部资源。
  // 失败/边界：handle 非 CQ、CQ 非 ACTIVE、CQ 有 outstanding ID、或依赖 QP/其它资源仍有活动事务时返回错误；失败路径不写入 registry，原 CQ 快照保持 ACTIVE。
  //   schema/投影/validate 失败、入口 epoch/source 变化及锁忙也不提交 QUIESCING。
  virtual function rdma_status begin_cq_resize(rdma_handle handle);
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_status status;
    rdma_resource_activity_blocker_snapshot blockers;
    rdma_resource source_resource;
    longint unsigned epoch_snapshot;
    string key;

    epoch_snapshot = publication_epoch;
    status = registry_schema_status("begin CQ resize");
    if (!status.ok()) return status;
    status = lookup(handle, authoritative);
    if (!status.ok()) return status;
    if (authoritative == null || authoritative.handle == null ||
        authoritative.handle.kind != RDMA_RESOURCE_CQ)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQ resize handle is not a CQ");
    key = resource_key(authoritative.handle);
    if (!registry.exists(key) || registry[key] == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "CQ resize authority is missing");
    source_resource = registry[key];
    if (registry[key].state != RDMA_RESOURCE_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "only ACTIVE CQ can begin resize");
    if (registry[key].outstanding_ids.size() != 0)
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "CQ has outstanding manager operations");
    // A CQ may remain referenced by an idle QP while its ring is replaced.
    // The detached snapshot distinguishes that allowed case from a non-QP
    // dependent or a QP carrying manager-visible work without rereading the
    // mutable registry in a second policy-specific loop.
    snapshot_activity_blockers(registry[key], blockers);
    if (rdma_resource_dependency_policy::blocks_release(
          blockers, RDMA_RESOURCE_RELEASE_CQ_RESIZE))
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "CQ has an active dependent resource");
    status = project_resource_value(registry[key], "begin CQ resize",
                                    replacement);
    if (!status.ok()) return status;
    replacement.state = RDMA_RESOURCE_QUIESCING;
    status = replacement.validate();
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "CQ quiesce validation returned null") : status;
    return commit_registry_replacement(
      key, replacement, "begin CQ resize", epoch_snapshot, source_resource
    );
  endfunction

  // 功能：replace_active_cq 对已 QUIESCING 的 CQ 原子发布新的 ACTIVE geometry/backing，同时验证 manager-owned identity、依赖、queue plan 和 release authority 不变。
  // 输入/输出及副作用：candidate（输入）；replace_active_cq 读取 candidate 并在所有检查通过后单次替换 registry CQ；函数返回 rdma_status，不直接释放旧 backing。
  // 失败/边界：candidate 为空/类型或状态错误、registry 非 QUIESCING、ring/ref geometry 不匹配、queue plan/身份/依赖/outstanding 改变或 validation 失败时拒绝，registry 保持原值。
  //   入口 epoch/source 冲突和锁忙同样拒绝；不会发布旧 geometry 覆盖外部窗口内的新状态。
  virtual function rdma_status replace_active_cq(rdma_cq candidate);
    rdma_resource authoritative;
    rdma_resource replacement_resource;
    rdma_cq authoritative_cq;
    rdma_cq replacement_cq;
    rdma_queue_ring_layout ring;
    rdma_queue_backing_ref ring_ref;
    rdma_status status;
    rdma_resource source_resource;
    longint unsigned epoch_snapshot;
    string key;
    int ring_count;
    int ref_count;

    epoch_snapshot = publication_epoch;
    if (candidate == null || candidate.handle == null ||
        candidate.handle.kind != RDMA_RESOURCE_CQ)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQ replacement candidate is invalid");
    if (candidate.state != RDMA_RESOURCE_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "CQ replacement candidate is not ACTIVE");
    status = lookup(candidate.handle, authoritative);
    if (!status.ok()) return status;
    if (authoritative == null || authoritative.handle == null ||
        authoritative.handle.kind != RDMA_RESOURCE_CQ ||
        !$cast(authoritative_cq, authoritative))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "CQ replacement authority is incompatible");
    key = resource_key(authoritative.handle);
    source_resource = registry[key];
    if (!registry.exists(key) || registry[key] == null ||
        registry[key].state != RDMA_RESOURCE_QUIESCING)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "CQ replacement requires QUIESCING authority");
    if (candidate.queue_plan == null ||
        candidate.queue_plan.resource_kind != RDMA_RESOURCE_CQ)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "CQ replacement queue plan is missing");
    ring_count = 0;
    ring = null;
    foreach (candidate.queue_plan.rings[i]) begin
      if (candidate.queue_plan.rings[i] != null &&
          candidate.queue_plan.rings[i].role == RDMA_QUEUE_ROLE_CQ_RING) begin
        ring_count++;
        ring = candidate.queue_plan.rings[i];
      end
    end
    ref_count = 0;
    ring_ref = null;
    foreach (candidate.queue_plan.refs[i]) begin
      if (candidate.queue_plan.refs[i] != null &&
          candidate.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING) begin
        ref_count++;
        ring_ref = candidate.queue_plan.refs[i];
      end
    end
    if (ring_count != 1 || ref_count != 1 || ring == null ||
        ring_ref == null || ring.depth != candidate.depth ||
        ring.entry_size_bytes != candidate.cqe_size_bytes ||
        ring_ref.mapping == null || ring_ref.mapping.state != RDMA_MAPPING_ACTIVE ||
        ring_ref.length != ring.storage_bytes ||
        candidate.queue_iova.value != ring_ref.mapping.iova.value)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQ replacement ring geometry is inconsistent");
    status = candidate.validate();
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "CQ replacement validation returned null") : status;
    status = publication_identity_status(candidate, authoritative);
    if (!status.ok()) return status;
    status = project_public_resource_value(candidate, "replace active CQ",
                                           replacement_resource);
    if (!status.ok()) return status;
    if (!$cast(replacement_cq, replacement_resource))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "CQ replacement projection type mismatch");
    replacement_cq.state = RDMA_RESOURCE_ACTIVE;
    status = replacement_cq.validate();
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "projected CQ replacement validation returned null") : status;
    // The helper below is the sole publication point.  All detached projections
    // and geometry checks above are deliberately completed first.
    return commit_registry_replacement(
      key, replacement_cq, "replace active CQ", epoch_snapshot, source_resource
    );
  endfunction

  // 功能：attach_qp_programming 将带 qp_plan/QPC 的 ALLOCATED 候选附着到干净 QP reservation，
  //   发布 PROGRAMMED；保留旧代际 exact-incarnation 的恢复登记入口。
  // 输入/输出及副作用：candidate 提供 detached 编程证据；成功替换 registry 并推进 epoch，
  //   不执行硬件提交、不接管 backing；epoch 在首次投影前、source 在 authority 投影前冻结。
  // 失败/边界：候选不完整、目标非干净 reservation、identity/validate 失败或 OCC/锁冲突拒绝。
  //   lookup 的 STALE_GENERATION 仅在同一旧 incarnation 仍在 registry 时进入 fallback；
  //   未知旧句柄保留原错误，fallback 投影失败优先于最终 OCC 检查。
  virtual function rdma_status attach_qp_programming(rdma_qp candidate);
    rdma_resource authoritative;
    rdma_resource projected;
    rdma_qp replacement;
    rdma_qp authoritative_qp;
    rdma_status status;
    rdma_resource source_resource;
    longint unsigned epoch_snapshot;
    string key;

    epoch_snapshot = publication_epoch;
    status = project_public_resource_value(candidate, "attach QP programming",
                                           projected);
    if (!status.ok() || !$cast(replacement, projected))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "QP programming candidate is incompatible"
      ) : status;
    if (replacement.state != RDMA_RESOURCE_ALLOCATED ||
        replacement.qp_plan == null || replacement.programmed_qpc == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP programming requires a complete ALLOCATED replacement"
      );
    status = lookup(replacement.handle, authoritative);
    if (status.ok())
      source_resource = registry[resource_key(authoritative.handle)];
    if (!status.ok() && status.code == RDMA_SC_STALE_GENERATION) begin
      key = resource_key(replacement.handle);
      if (registry.exists(key) && registry[key] != null &&
          registry[key].handle != null &&
          same_handle_instance(registry[key].handle, replacement.handle)) begin
        // 旧代际 lookup 不返回资源；必须在 fallback 的外部 projection 前冻结引用，
        // 不能在 projection 返回后重取而把等值 source 替换当作本次校验结果。
        source_resource = registry[key];
        status = project_resource_value(
          source_resource, "attach exact-old QP recovery programming",
          authoritative
        );
      end
    end
    if (!status.ok() || !$cast(authoritative_qp, authoritative))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "QP programming target is not a QP"
      ) : status;
    key = resource_key(authoritative.handle);
    if (registry[key].state != RDMA_RESOURCE_ALLOCATED ||
        staged_allocations.exists(key) || authoritative_qp.qp_plan != null ||
        authoritative_qp.programmed_qpc != null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP programming target is not a clean reservation"
      );
    status = publication_identity_status(replacement, authoritative);
    if (!status.ok())
      return status;
    replacement.state = RDMA_RESOURCE_PROGRAMMED;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP programming validation returned null"
      );
    if (!status.ok())
      return status;
    return commit_registry_replacement(
      key, replacement, "attach QP programming", epoch_snapshot, source_resource
    );
  endfunction

  // 功能：commit_qp_semantic_state 提交 ACTIVE QP 的 RESET→INIT 语义迁移，保留硬件 QPC image。
  // 输入/输出及副作用：qp_h 定位 QP，state 必须为 INIT；成功只更新 detached qp_state 并
  //   推进 epoch，不执行 QPC modify、不推进队列游标。
  // 失败/边界：目标非 QP/非 ACTIVE RESET、请求非 INIT、投影/validate 失败、入口 epoch/source
  //   变化或锁忙时保持旧 QP；重复 INIT 不幂等成功。
  virtual function rdma_status commit_qp_semantic_state(
    rdma_handle qp_h,
    rdma_qp_state_e state
  );
    rdma_resource authoritative;
    rdma_resource projected;
    rdma_qp replacement;
    rdma_status status;
    rdma_resource source_resource;
    longint unsigned epoch_snapshot;
    string key;

    epoch_snapshot = publication_epoch;
    status = lookup(qp_h, authoritative);
    if (!status.ok() || authoritative.handle.kind != RDMA_RESOURCE_QP)
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "semantic-state target is not a QP"
      ) : status;
    key = resource_key(authoritative.handle);
    source_resource = registry[key];
    if (registry[key].state != RDMA_RESOURCE_ACTIVE ||
        !$cast(replacement, registry[key]) ||
        replacement.qp_state != RDMA_QPS_RESET || state != RDMA_QPS_INIT)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP semantic-only commit requires ACTIVE RESET to INIT"
      );
    status = project_resource_value(registry[key], "commit QP semantic state",
                                    projected);
    if (!status.ok() || !$cast(replacement, projected))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP semantic-state projection failed"
      ) : status;
    replacement.qp_state = state;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP semantic-state validation returned null"
      );
    if (!status.ok())
      return status;
    return commit_registry_replacement(
      key, replacement, "commit QP semantic state", epoch_snapshot, source_resource
    );
  endfunction

  // 功能：commit_qp_programmed 校验普通或 ERROR reconciliation 的 QP programmed image，
  //   并以双账本 OCC helper 原子发布 ACTIVE replacement，reconciliation 成功时同步清除
  //   已消费的 recovery record。
  // 输入/输出及副作用：candidate 为输入；函数只更新 manager registry/recovery ledger，
  //   不取得外部 QP backing 所有权，并在成功后推进 publication_epoch。
  // 失败/边界：candidate authority、QPC/recovery ambiguity、release completion、validate、
  //   epoch/source 或 mutation guard 任一条件失败时保持原状态，不推进游标、不半清 recovery。
  virtual function rdma_status commit_qp_programmed(rdma_qp candidate);
    rdma_resource authoritative;
    rdma_resource projected;
    rdma_qp authoritative_qp;
    rdma_qp replacement;
    rdma_qp expected_replacement;
    rdma_qpc_model requested_qpc;
    rdma_qp_state_e requested_qp_state;
    rdma_recovery_record recovery;
    rdma_status status;
    bit release_complete;
    string key;
    bit reconciliation;
    bit restore_prior;
    rdma_resource source_resource;
    rdma_recovery_record source_recovery;
    bit source_recovery_exists;
    longint unsigned epoch_snapshot;

    status = project_public_resource_value(candidate, "commit QP programmed",
                                           projected);
    if (!status.ok() || !$cast(replacement, projected))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "programmed QP candidate is incompatible"
      ) : status;
    status = lookup(replacement.handle, authoritative);
    if (!status.ok() || !$cast(authoritative_qp, authoritative))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "programmed target is not a QP"
      ) : status;
    key = resource_key(authoritative.handle);
    status = publication_identity_status(replacement, authoritative);
    if (!status.ok())
      return status;
    if (!same_qp_plan_value(replacement.qp_plan,
                            authoritative_qp.qp_plan))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "programmed QP backing authority changed"
      );

    reconciliation = registry[key].state == RDMA_RESOURCE_ERROR;
    if (!reconciliation) begin
      if (registry[key].state != RDMA_RESOURCE_ACTIVE ||
          replacement.state != RDMA_RESOURCE_ACTIVE)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE, "programmed QP commit requires ACTIVE state"
        );
      requested_qp_state = replacement.qp_state;
      status = project_qpc_value(
        replacement.programmed_qpc, "commit QP requested QPC",
        requested_qpc
      );
      if (!status.ok() || requested_qpc == null)
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "requested QP programmed QPC projection failed"
        ) : status;
      status = project_resource_value(
        registry[key], "commit QP authoritative resource", projected
      );
      if (!status.ok() || !$cast(replacement, projected))
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "authoritative QP programmed projection failed"
        ) : status;
      replacement.programmed_qpc = requested_qpc;
      replacement.qp_state = requested_qp_state;
    end
    else begin
      status = recovery_entry_schema_status(key, "commit QP programmed");
      if (!status.ok())
        return status;
      if (!recovery_records.exists(key))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE, "ERROR QP lacks modify recovery"
        );
      recovery = recovery_records[key];
      restore_prior = recovery.qp_recovery_valid &&
        recovery.qp_recovery != null &&
        same_qpc_value(replacement.programmed_qpc,
                       recovery.qp_recovery.prior_qpc);
      if (!recovery.qp_recovery_valid || recovery.qp_recovery == null ||
          recovery.qp_recovery.intent !=
            RDMA_QP_RECOVER_MODIFY_RECONCILE ||
          !(restore_prior ||
            same_qpc_value(replacement.programmed_qpc,
                           recovery.qp_recovery.candidate_qpc)))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "programmed QP does not match a reconciliation candidate"
        );
      status = project_resource_value(
        registry[key], "commit QP expected reconciliation", projected
      );
      if (!status.ok() || !$cast(expected_replacement, projected))
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "expected QP reconciliation projection failed"
        ) : status;
      status = project_qpc_value(
        restore_prior ? recovery.qp_recovery.prior_qpc :
                        recovery.qp_recovery.candidate_qpc,
        "commit QP expected reconciliation QPC",
        expected_replacement.programmed_qpc
      );
      if (!status.ok() || expected_replacement.programmed_qpc == null)
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "expected QP reconciliation QPC projection failed"
        ) : status;
      // The ERROR registry snapshot deliberately carries no semantic
      // lifecycle state that can be used for reconciliation.  For a prior
      // image selected after RESET→INIT→RTR ambiguity, the programmed image
      // is still RESET while software had already advanced to INIT; restore
      // that explicit semantic state rather than publishing ERROR.
      expected_replacement.qp_state = restore_prior ?
        ((expected_replacement.programmed_qpc.state == RDMA_QPS_RESET &&
          recovery.qp_recovery.candidate_qpc != null &&
          recovery.qp_recovery.candidate_qpc.state != RDMA_QPS_RESET) ?
         RDMA_QPS_INIT : expected_replacement.programmed_qpc.state) :
        expected_replacement.programmed_qpc.state;
      expected_replacement.state = RDMA_RESOURCE_ACTIVE;
      if (!same_qp_reconciliation_value(replacement,
                                         expected_replacement))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "programmed QP is not the complete reconciliation replacement"
        );
      if (recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE ||
          recovery.qp_recovery.ambiguous_ticket != null)
        return rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "QP recovery ambiguity is not resolved"
        );
      if (recovery.qp_recovery.staging_mapping != null) begin
        status = query_owned_release_completion(
          recovery.qp_recovery.staging_mapping, release_complete
        );
        if (status == null || !status.ok() || !release_complete)
          return rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            "QP recovery staging release is not complete"
          );
      end
      if (recovery.qp_recovery.query_mapping != null) begin
        status = recovery.qp_recovery.query_mapping_recovery_only ?
          query_qp_recovery_release_completion(
            recovery.qp_recovery.query_mapping, release_complete
          ) :
          query_owned_release_completion(
            recovery.qp_recovery.query_mapping, release_complete
          );
        if (status == null || !status.ok() || !release_complete)
          return rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            "QP recovery query release is not complete"
          );
      end
      replacement = expected_replacement;
    end
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "programmed QP validation returned null"
      );
    if (!status.ok())
      return status;
    epoch_snapshot = publication_epoch;
    source_resource = registry[key];
    source_recovery_exists = recovery_records.exists(key);
    source_recovery = source_recovery_exists ? recovery_records[key] : null;
    if (source_resource == null ||
        source_recovery_exists && source_recovery == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "programmed QP source ledger is incomplete"
      );
    return commit_resource_recovery_replacement(
      key, replacement, null, 1'b0, reconciliation, 1'b0,
      source_resource, source_recovery, source_recovery_exists,
      epoch_snapshot, "commit QP programmed"
    );
  endfunction

  // 功能：执行 mark_qp_error 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：qp_h（输入）、recovery（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过
  //   output 返回结果。
  // 失败/边界：mark_qp_error 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  virtual function rdma_status mark_qp_error(
    rdma_handle qp_h,
    rdma_qp_recovery_state recovery
  );
    rdma_resource authoritative;
    rdma_resource projected;
    rdma_qp authoritative_qp;
    rdma_qp retained_qp;
    rdma_qp replacement;
    rdma_qp_recovery_state recovery_copy;
    rdma_qp_recovery_state existing_recovery;
    rdma_recovery_record record_copy;
    rdma_status status;
    string key;
    bit error_replacement;
    bit progress_changed;
    bit setting_ambiguity;
    bit clearing_ambiguity;
    bit refreshing_pending;
    bit normalizing_occ_role;
    bit stale_recovery_allowed;
    bit preprogram_publication;
    bit preprogram_shape;
    rdma_function_handle recovery_owner;
    rdma_handle recovery_qp_h;
    rdma_resource source_resource;
    rdma_recovery_record source_recovery;
    bit source_recovery_exists;
    longint unsigned epoch_snapshot;

    preprogram_shape = recovery != null &&
      recovery.intent == RDMA_QP_RECOVER_CREATE_ROLLBACK &&
      recovery.ambiguous_operation == RDMA_QP_AMBIG_NONE &&
      recovery.ambiguous_ticket == null && recovery.prior_qpc == null &&
      recovery.candidate_qpc == null && recovery.query_mapping == null;
    preprogram_publication = 1'b0;

    status = lookup(qp_h, authoritative);
    if (!status.ok() && status.code == RDMA_SC_STALE_GENERATION &&
        recovery != null) begin
      key = resource_key(qp_h);
      stale_recovery_allowed = 1'b0;
      if (registry.exists(key) && registry[key] != null &&
          registry[key].handle != null &&
          same_handle_instance(registry[key].handle, qp_h) &&
          $cast(retained_qp, registry[key])) begin
        if ((recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE ||
             recovery.has_pending_hardware_step) &&
            (recovery.ambiguous_ticket != null ||
             recovery.has_pending_hardware_step)) begin
          status = recovery.validate();
          stale_recovery_allowed = status != null && status.ok();
        end
        else if (preprogram_shape &&
                 registry[key].state == RDMA_RESOURCE_ALLOCATED &&
                 !recovery_records.exists(key)) begin
          status = project_qp_recovery_value(
            recovery, "mark stale pre-program QP ERROR", recovery_copy
          );
          if (status.ok() && recovery_copy != null)
            status = recovery_copy.validate();
          if (status != null && status.ok())
            status = rdma_qp_partial_plan_authority(
              recovery_copy.qp_plan, recovery_owner, recovery_qp_h
            );
          // 设计：partial-plan authority 成功后仍要求 recovery_qp_h、
          // recovery_owner 与 registry owner 非空；只有同一 Function
          // incarnation 才能放宽 stale-generation recovery gate。
          stale_recovery_allowed = status != null && status.ok() &&
            recovery_qp_h != null && recovery_owner != null &&
            same_handle_instance(recovery_qp_h, registry[key].handle) &&
            registry[key].owner != null &&
            same_handle_instance(recovery_owner, registry[key].owner);
        end
        else if (recovery.intent == RDMA_QP_RECOVER_CREATE_ROLLBACK &&
                 recovery.ambiguous_operation == RDMA_QP_AMBIG_NONE &&
                 recovery.ambiguous_ticket == null &&
                 ((recovery.candidate_qpc != null &&
                   same_qpc_value(recovery.candidate_qpc,
                                  retained_qp.programmed_qpc)) ||
                  (recovery.candidate_qpc == null &&
                   retained_qp.state == RDMA_RESOURCE_PROGRAMMED &&
                   same_qp_plan_value(recovery.qp_plan,
                                      retained_qp.qp_plan)))) begin
          status = recovery.validate();
          stale_recovery_allowed = status != null && status.ok();
        end
        if (stale_recovery_allowed)
          status = project_resource_value(
            registry[key], "mark stale in-flight QP ERROR", authoritative
          );
        else
          status = rdma_status::make(
            RDMA_SC_STALE_GENERATION,
            "stale QP recovery lacks retained hardware authority"
          );
      end
    end
    if (!status.ok() || !$cast(authoritative_qp, authoritative))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "QP ERROR target is not a QP"
      ) : status;
    key = resource_key(authoritative.handle);
    preprogram_publication = preprogram_shape &&
      registry[key].state == RDMA_RESOURCE_ALLOCATED;
    if (preprogram_publication) begin
      status = project_qp_recovery_value(
        recovery, "mark pre-program QP ERROR", recovery_copy
      );
      if (!status.ok() || recovery_copy == null)
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "pre-program QP recovery projection is empty"
        ) : status;
      status = recovery_copy.validate();
      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "pre-program QP recovery validation returned null"
        );
      if (!status.ok())
        return status;
      status = rdma_qp_partial_plan_authority(
        recovery_copy.qp_plan, recovery_owner, recovery_qp_h
      );
      if (!status.ok())
        return status;
      if (recovery_copy.qp_plan.cleanup_complete ||
          recovery_copy.qp_plan.sq_pd_flush_complete ||
          recovery_copy.qp_plan.rq_pd_flush_complete)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "new pre-program QP recovery carries flush progress"
        );
      foreach (recovery_copy.role_complete[i]) begin
        if (recovery_copy.role_complete[i])
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "new pre-program QP recovery carries cleanup progress"
          );
      end
    end
    error_replacement =
      (registry[key].state == RDMA_RESOURCE_ERROR) &&
      recovery_records.exists(key) &&
      (recovery_records[key] != null) &&
      recovery_records[key].qp_recovery_valid &&
      (recovery_records[key].qp_recovery != null);
    if ((preprogram_publication &&
         (registry[key].state != RDMA_RESOURCE_ALLOCATED ||
          recovery_records.exists(key) || staged_allocations.exists(key))) ||
        (!preprogram_publication &&
         ((!(registry[key].state inside {RDMA_RESOURCE_PROGRAMMED,
                                         RDMA_RESOURCE_ACTIVE,
                                         RDMA_RESOURCE_QUIESCING}) &&
           !error_replacement) ||
          ((registry[key].state != RDMA_RESOURCE_ERROR) &&
           recovery_records.exists(key)))))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP cannot enter ERROR from its current state"
      );
    if (error_replacement) begin
      status = recovery_entry_schema_status(key, "replace QP ERROR recovery");
      if (!status.ok())
        return status;
    end
    // 所有外部 projection 完成后冻结双账本 OCC 证据；helper 只在最终写回时
    // 持有 guard，避免 factory/callback 重入时锁住 manager。
    epoch_snapshot = publication_epoch;
    source_resource = registry[key];
    source_recovery_exists = recovery_records.exists(key);
    source_recovery = source_recovery_exists ? recovery_records[key] : null;
    if (source_resource == null ||
        source_recovery_exists && source_recovery == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP ERROR source ledger is incomplete"
      );
    if (!preprogram_publication) begin
      status = project_qp_recovery_value(recovery, "mark QP ERROR",
                                         recovery_copy);
      if (!status.ok() || recovery_copy == null)
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT, "QP recovery projection is empty"
        ) : status;
      status = recovery_copy.validate();
      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE, "QP recovery validation returned null"
        );
      if (!status.ok())
        return status;
    end
    if (preprogram_publication) begin
      // 设计：pre-program QP 尚无 QPC/plan 时，recovery_owner 与已登记
      // authoritative owner 必须先通过非空门禁，再比较完整 handle identity；
      // 失配继续走 INVALID_ARGUMENT authority-changed，后续 SRQ 检查与发布顺序不变。
      if (authoritative_qp.qp_plan != null ||
          authoritative_qp.programmed_qpc != null ||
          !same_handle_instance(recovery_qp_h, authoritative_qp.handle) ||
          recovery_owner == null || authoritative_qp.owner == null ||
          !same_handle_instance(recovery_owner, authoritative_qp.owner) ||
          (authoritative_qp.srq_h == null) !=
            (recovery_copy.qp_plan.rq_source_h == null) ||
          (authoritative_qp.srq_h != null &&
           !same_handle_instance(authoritative_qp.srq_h,
             recovery_copy.qp_plan.rq_source_h)))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "pre-program QP recovery authority changed"
        );
    end
    else if (!same_qp_plan_value(authoritative_qp.qp_plan,
                                 recovery_copy.qp_plan) ||
             !same_context_value(authoritative_qp.qp_plan.context_ref,
                                 recovery_copy.context_ref))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "QP recovery authority changed"
      );
    if (recovery_copy.intent inside {
          RDMA_QP_RECOVER_MODIFY_RECONCILE,
          RDMA_QP_RECOVER_NORMAL_DESTROY
        } &&
        !same_qpc_value(recovery_copy.prior_qpc,
                         authoritative_qp.programmed_qpc))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP recovery prior QPC is not authoritative"
      );
    if (recovery_copy.intent == RDMA_QP_RECOVER_CREATE_ROLLBACK &&
        recovery_copy.candidate_qpc != null &&
        !same_qpc_value(recovery_copy.candidate_qpc,
                         authoritative_qp.programmed_qpc))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP create recovery candidate QPC is not authoritative"
      );
    if (error_replacement) begin
      existing_recovery = recovery_records[key].qp_recovery;
      setting_ambiguity =
        existing_recovery.ambiguous_operation == RDMA_QP_AMBIG_NONE &&
        existing_recovery.ambiguous_ticket == null &&
        recovery_copy.ambiguous_operation != RDMA_QP_AMBIG_NONE &&
        (recovery_copy.ambiguous_ticket != null ||
         recovery_copy.has_pending_hardware_step);
      clearing_ambiguity =
        existing_recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE &&
        (existing_recovery.ambiguous_ticket != null ||
         existing_recovery.has_pending_hardware_step) &&
        recovery_copy.ambiguous_operation == RDMA_QP_AMBIG_NONE &&
        recovery_copy.ambiguous_ticket == null;
      normalizing_occ_role =
        clearing_ambiguity &&
        existing_recovery.ambiguous_operation == RDMA_QP_AMBIG_OCC_FLUSH &&
        existing_recovery.ambiguous_role inside {
          RDMA_QUEUE_ROLE_QP_SQ_PD, RDMA_QUEUE_ROLE_QP_RQ_PD
        } &&
        recovery_copy.ambiguous_role == RDMA_QUEUE_ROLE_QP_SQ_RING;
      // A retry may need to refresh an existing ticketless ambiguity marker
      // (notably destroy ERROR MODIFY) when the adapter again returns no
      // ticket.  Preserve the operation/role authority while allowing the
      // marker to be durably re-persisted; no progress or retained authority
      // may change in this transition.
      refreshing_pending =
        existing_recovery.has_pending_hardware_step &&
        recovery_copy.ambiguous_operation ==
          existing_recovery.ambiguous_operation &&
        recovery_copy.ambiguous_role == existing_recovery.ambiguous_role &&
        (recovery_copy.has_pending_hardware_step ||
         recovery_copy.ambiguous_ticket != null);
      progress_changed = 1'b0;
      foreach (existing_recovery.role_complete[i]) begin
        if (existing_recovery.role_complete[i] !=
            recovery_copy.role_complete[i]) begin
          if (!setting_ambiguity || existing_recovery.role_complete[i] ||
              !recovery_copy.role_complete[i] ||
              (recovery_copy.ambiguous_operation ==
                 RDMA_QP_AMBIG_OCC_FLUSH &&
               i == recovery_copy.ambiguous_role))
            progress_changed = 1'b1;
          else begin
            case (i)
              RDMA_QUEUE_ROLE_QP_SQ_RING:
                if (!existing_recovery.qp_plan.cleanup_complete)
                  progress_changed = 1'b1;
              RDMA_QUEUE_ROLE_QP_SQ_PD:
                if (!existing_recovery.qp_plan.sq_pd_flush_complete)
                  progress_changed = 1'b1;
              RDMA_QUEUE_ROLE_QP_RQ_PD:
                if (!existing_recovery.qp_plan.rq_pd_flush_complete)
                  progress_changed = 1'b1;
              default: progress_changed = 1'b1;
            endcase
          end
        end
      end
      if (!setting_ambiguity && !clearing_ambiguity && !refreshing_pending)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "QP ERROR ambiguity transition is out of order"
        );
      if ((!setting_ambiguity && !normalizing_occ_role &&
           recovery_copy.ambiguous_role !=
             existing_recovery.ambiguous_role) ||
          recovery_copy.intent != existing_recovery.intent ||
          (!clearing_ambiguity &&
           recovery_copy.error_modify_complete !=
             existing_recovery.error_modify_complete) ||
          (!clearing_ambiguity &&
           recovery_copy.delete_complete != existing_recovery.delete_complete) ||
          !same_qpc_value(recovery_copy.prior_qpc,
                           existing_recovery.prior_qpc) ||
          !same_qpc_value(recovery_copy.candidate_qpc,
                           existing_recovery.candidate_qpc) ||
          !same_qp_plan_value(recovery_copy.qp_plan,
                              existing_recovery.qp_plan) ||
          !same_context_value(recovery_copy.context_ref,
                              existing_recovery.context_ref) ||
          !same_mapping_value(recovery_copy.staging_mapping,
                              existing_recovery.staging_mapping) ||
          recovery_copy.staging_mapping != null &&
            !same_owned_mapping_authority(
              recovery_copy.staging_mapping,
              existing_recovery.staging_mapping
            ) ||
          !same_mapping_value(recovery_copy.query_mapping,
                              existing_recovery.query_mapping) ||
          recovery_copy.query_mapping_recovery_only !=
            existing_recovery.query_mapping_recovery_only ||
          (existing_recovery.query_presence_known &&
           (!recovery_copy.query_presence_known ||
            recovery_copy.query_presence != existing_recovery.query_presence)) ||
          (recovery_copy.has_pending_hardware_step !=
            existing_recovery.has_pending_hardware_step &&
            !clearing_ambiguity && !refreshing_pending) ||
          recovery_copy.query_mapping != null &&
            (recovery_copy.query_mapping_recovery_only ?
              !same_recovery_mapping_value(
                recovery_copy.query_mapping,
                existing_recovery.query_mapping
              ) :
              !same_owned_mapping_authority(
                recovery_copy.query_mapping,
                existing_recovery.query_mapping
              )) ||
          !rdma_qp_recovery_opcode_equivalent(
            recovery_copy.create_opcode, existing_recovery.create_opcode
          ) ||
          !rdma_qp_recovery_opcode_equivalent(
            recovery_copy.modify_opcode, existing_recovery.modify_opcode
          ) ||
          !rdma_qp_recovery_opcode_equivalent(
            recovery_copy.delete_opcode, existing_recovery.delete_opcode
          ) ||
          !rdma_qp_recovery_opcode_equivalent(
            recovery_copy.query_opcode, existing_recovery.query_opcode
          ) ||
          !rdma_qp_recovery_opcode_equivalent(
            recovery_copy.occ_opcode, existing_recovery.occ_opcode
          ) || progress_changed)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "QP ERROR replacement changed retained authority or progress"
        );
    end
    status = project_resource_value(registry[key], "mark QP ERROR resource",
                                    projected);
    if (!status.ok() || !$cast(replacement, projected))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP ERROR resource projection failed"
      ) : status;
    replacement.state = RDMA_RESOURCE_ERROR;
    if (preprogram_publication) begin
      status = project_qp_plan_value(
        recovery_copy.qp_plan, "mark pre-program QP ERROR plan",
        replacement.qp_plan
      );
      if (!status.ok())
        return status;
      replacement.programmed_qpc = null;
      replacement.transport = replacement.qp_plan.transport;
      replacement.sq_depth = replacement.qp_plan.sq_depth;
      replacement.rq_depth = replacement.qp_plan.rq_depth;
      if (replacement.qp_plan.sq_ref != null)
        replacement.sq_iova.value =
          replacement.qp_plan.sq_ref.mapping.iova.value +
          replacement.qp_plan.sq_ref.mapping_offset;
      if (replacement.qp_plan.rq_source_h == null &&
          replacement.qp_plan.rq_ref != null)
        replacement.rq_iova.value =
          replacement.qp_plan.rq_ref.mapping.iova.value +
          replacement.qp_plan.rq_ref.mapping_offset;
      else
        replacement.rq_iova.value = 0;
    end
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP ERROR resource validation returned null"
      );
    if (!status.ok())
      return status;

    if (error_replacement) begin
      status = project_recovery_value(
        recovery_records[key], "replace QP ERROR record", record_copy
      );
      if (!status.ok())
        return status;
      record_copy.qp_recovery = recovery_copy;
      // The nested QP recovery state is the authoritative source once a
      // CREATE/DELETE ambiguity has been reconciled by a QPC_QUERY (or by a
      // terminal CMQ result).  Keep the record-level presence in sync before
      // validation; otherwise an UNKNOWN top-level value with a now-cleared
      // nested ticket is rejected as an impossible recovery schema.
      if (recovery_copy.query_presence_known)
        record_copy.hardware_presence = recovery_copy.query_presence;
    end
    else begin
      record_copy = new("qp_recovery_record");
      status = project_handle_value(authoritative.handle, "QP recovery handle",
                                    record_copy.resource_h);
      if (!status.ok())
        return status;
      record_copy.hardware_presence =
        (recovery_copy.intent == RDMA_QP_RECOVER_CREATE_ROLLBACK &&
         recovery_copy.ambiguous_operation == RDMA_QP_AMBIG_CREATE) ||
        (recovery_copy.intent == RDMA_QP_RECOVER_NORMAL_DESTROY &&
         recovery_copy.ambiguous_operation == RDMA_QP_AMBIG_DELETE) ?
          RDMA_HW_PRESENCE_UNKNOWN :
        ((recovery_copy.intent == RDMA_QP_RECOVER_CREATE_ROLLBACK &&
          recovery_copy.ambiguous_operation == RDMA_QP_AMBIG_NONE &&
          recovery_copy.candidate_qpc == null) ||
         (recovery_copy.intent == RDMA_QP_RECOVER_NORMAL_DESTROY &&
          recovery_copy.delete_complete)) ?
          RDMA_HW_PRESENCE_ABSENT : RDMA_HW_PRESENCE_PRESENT;
      record_copy.primary_status = rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED, "QP requires lifecycle recovery"
      );
      record_copy.qp_recovery_valid = 1'b1;
      record_copy.qp_recovery = recovery_copy;
      if (recovery_copy.query_presence_known)
        record_copy.hardware_presence = recovery_copy.query_presence;
    end
    status = record_copy.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP recovery record validation returned null"
      );
    if (!status.ok())
      return status;

    // Durable recovery authority and ERROR resource are published together.
    return commit_resource_recovery_replacement(
      key, replacement, record_copy, 1'b1, 1'b0, 1'b1,
      source_resource, source_recovery, source_recovery_exists,
      epoch_snapshot, "mark QP ERROR"
    );
  endfunction

  // Persist destroy recovery milestones that are not represented by backing
  // cleanup role bits (the ERROR transition and QPC_DELETE).  This operation
  // never changes the resource state or any authority-bearing identity; it
  // only replaces the detached recovery snapshot after full validation.
  // 功能：update_qp_recovery_progress 投影并提交 ERROR QP 的恢复进度，在保留 intent/QPC/
  //   mapping/opcode authority 的同时，通过 recovery-only OCC helper 原子替换记录。
  // 输入/输出及副作用：qp_h、recovery 为输入；函数只更新 manager 自有 recovery_records，
  //   不取得调用方 mapping/backing 所有权，并在成功后推进 publication_epoch。
  // 失败/边界：目标不是 QP、缺少 ERROR record、projection/validate 失败、保留 authority
  //   变化、epoch 过期、source 引用变化或 guard 忙时拒绝且不写回部分记录。
  virtual function rdma_status update_qp_recovery_progress(
    rdma_handle qp_h,
    rdma_qp_recovery_state recovery
  );
    rdma_resource authoritative;
    rdma_recovery_record existing_record;
    rdma_recovery_record replacement_record;
    rdma_qp_recovery_state existing_recovery;
    rdma_qp_recovery_state recovery_copy;
    rdma_status status;
    longint unsigned epoch_snapshot;
    string key;

    status = lookup(qp_h, authoritative);
    if (!status.ok() || authoritative.handle.kind != RDMA_RESOURCE_QP)
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "QP recovery progress target is not a QP"
      ) : status;
    key = resource_key(authoritative.handle);
    if (registry[key].state != RDMA_RESOURCE_ERROR ||
        !recovery_records.exists(key) || recovery == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP recovery progress requires an ERROR recovery record"
      );
    existing_record = recovery_records[key];
    epoch_snapshot = publication_epoch;
    existing_recovery = existing_record == null ? null :
                        existing_record.qp_recovery;
    if (existing_record == null || !existing_record.qp_recovery_valid ||
        existing_recovery == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "QP recovery progress record is incomplete");
    status = project_qp_recovery_value(recovery,
                                       "QP recovery progress", recovery_copy);
    if (!status.ok() || recovery_copy == null)
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "QP recovery progress projection is empty"
      ) : status;
    status = recovery_copy.validate();
    if (!status.ok())
      return status;
    if (recovery_copy.intent != existing_recovery.intent ||
        !same_qpc_value(recovery_copy.prior_qpc, existing_recovery.prior_qpc) ||
        !same_qpc_value(recovery_copy.candidate_qpc,
                        existing_recovery.candidate_qpc) ||
        !same_context_value(recovery_copy.context_ref,
                            existing_recovery.context_ref) ||
        !same_mapping_value(recovery_copy.staging_mapping,
                            existing_recovery.staging_mapping) ||
        !same_mapping_value(recovery_copy.query_mapping,
                            existing_recovery.query_mapping) ||
        recovery_copy.query_mapping_recovery_only !=
          existing_recovery.query_mapping_recovery_only ||
        (existing_recovery.query_presence_known &&
         (!recovery_copy.query_presence_known ||
          recovery_copy.query_presence != existing_recovery.query_presence)) ||
        !rdma_qp_recovery_opcode_equivalent(
          recovery_copy.create_opcode, existing_recovery.create_opcode) ||
        !rdma_qp_recovery_opcode_equivalent(
          recovery_copy.modify_opcode, existing_recovery.modify_opcode) ||
        !rdma_qp_recovery_opcode_equivalent(
          recovery_copy.delete_opcode, existing_recovery.delete_opcode) ||
        !rdma_qp_recovery_opcode_equivalent(
          recovery_copy.query_opcode, existing_recovery.query_opcode) ||
        !rdma_qp_recovery_opcode_equivalent(
          recovery_copy.occ_opcode, existing_recovery.occ_opcode))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP recovery progress changed retained authority"
      );
    status = project_recovery_value(existing_record,
                                    "QP recovery progress record",
                                    replacement_record);
    if (!status.ok())
      return status;
    replacement_record.qp_recovery = recovery_copy;
    if (recovery_copy.query_presence_known)
      replacement_record.hardware_presence = recovery_copy.query_presence;
    else if (recovery_copy.intent == RDMA_QP_RECOVER_NORMAL_DESTROY &&
             recovery_copy.delete_complete)
      replacement_record.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    status = replacement_record.validate();
    if (!status.ok())
      return status;
    return commit_recovery_replacement(
      key, replacement_record, existing_record, epoch_snapshot,
      "QP recovery progress"
    );
  endfunction

  // Retain a query mapping allocated during recovery before any later
  // operation can drop its opaque release authority.  The mapping is allowed
  // to be attached only once, while the QP is already in ERROR and the
  // existing recovery record has no query authority.  This narrow mutation
  // keeps query allocation failures recoverable without permitting callers to
  // replace an established mapping identity.
  // 功能：retain_qp_query_mapping 在 ERROR QP recovery record 中登记一次 query mapping，
  //   先完成 owned/recovery-only projection，再经 recovery-only OCC helper 原子替换记录。
  // 输入/输出及副作用：qp_h、query_mapping、query_mapping_recovery_only 为输入；成功时
  //   只更新 manager recovery ledger 并推进 publication_epoch，不接管调用方传入 mapping。
  // 失败/边界：mapping 为空、目标非 ERROR QP、已有 query authority、projection/validate
  //   失败、epoch/source 变化或 guard 忙时拒绝，不留下半成品 mapping。
  virtual function rdma_status retain_qp_query_mapping(
    rdma_handle qp_h,
    rdma_dma_mapping query_mapping,
    bit query_mapping_recovery_only = 1'b0
  );
    rdma_resource authoritative;
    rdma_recovery_record existing_record;
    rdma_recovery_record replacement_record;
    rdma_qp_recovery_state recovery;
    rdma_dma_mapping projected_mapping;
    rdma_status status;
    longint unsigned epoch_snapshot;
    string key;

    if (query_mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP query mapping is null");
    status = lookup(qp_h, authoritative);
    if (!status.ok() || authoritative == null ||
        authoritative.handle.kind != RDMA_RESOURCE_QP)
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "QP query mapping target is not a QP") : status;
    key = resource_key(authoritative.handle);
    if (registry[key].state != RDMA_RESOURCE_ERROR ||
        !recovery_records.exists(key))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP query mapping requires an ERROR recovery record");
    existing_record = recovery_records[key];
    epoch_snapshot = publication_epoch;
    if (existing_record == null || !existing_record.qp_recovery_valid ||
        existing_record.qp_recovery == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "QP query mapping recovery record is incomplete");
    recovery = existing_record.qp_recovery;
    if (recovery.query_mapping != null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP query mapping authority is already retained");
    if (query_mapping_recovery_only)
      status = clone_recovery_mapping_value(
        query_mapping, "QP retained query recovery", projected_mapping);
    else
      status = clone_owned_mapping_value(
        query_mapping, "QP retained query", projected_mapping);
    if (!status.ok() || projected_mapping == null)
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP retained query mapping projection failed") : status;
    status = project_recovery_value(existing_record,
                                    "QP retained query record",
                                    replacement_record);
    if (!status.ok() || replacement_record == null ||
        replacement_record.qp_recovery == null)
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP retained query record projection failed") : status;
    replacement_record.qp_recovery.query_mapping = projected_mapping;
    replacement_record.qp_recovery.query_mapping_recovery_only =
      query_mapping_recovery_only;
    status = replacement_record.validate();
    if (!status.ok())
      return status;
    return commit_recovery_replacement(
      key, replacement_record, existing_record, epoch_snapshot,
      "QP retained query mapping"
    );
  endfunction

  // 功能：在 rdma_resource_manager 中，qp_plan_ref 读取或发布队列/QP 恢复进度快照，使恢复步骤可重复执行且不会重复释放资源。
  // 输入/输出及副作用：plan（输入）、role（输入）；qp_plan_ref 读取 plan、role 并使用字段 i；函数返回 rdma_qp_backing_ref，不取得调用方资源所有权。
  // 失败/边界：qp_plan_ref 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_qp_backing_ref qp_plan_ref(
    rdma_qp_backing_plan plan,
    rdma_queue_backing_role_e role
  );
    if (plan == null)
      return null;
    case (role)
      RDMA_QUEUE_ROLE_QP_SQ_RING: return plan.sq_ref;
      RDMA_QUEUE_ROLE_QP_SQ_SGB: return plan.sq_sgb_ref;
      RDMA_QUEUE_ROLE_QP_RQ_RING: return plan.rq_ref;
      RDMA_QUEUE_ROLE_QP_SQ_PD: return plan.sq_pd_ref;
      RDMA_QUEUE_ROLE_QP_RQ_PD: return plan.rq_pd_ref;
      default: begin
        foreach (plan.urc_refs[i])
          if (plan.urc_refs[i] != null && plan.urc_refs[i].role == role)
            return plan.urc_refs[i];
      end
    endcase
    return null;
  endfunction

  // 功能：qp_owned_cleanup_role_complete 比较 plan、role 与当前 authority/状态字段，返回布尔结果供上层执行精确分支。
  // 输入/输出及副作用：plan（输入）、role（输入）；qp_owned_cleanup_role_complete 读取 plan、role 并使用字段 backing_ref；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：qp_owned_cleanup_role_complete 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function bit qp_owned_cleanup_role_complete(
    rdma_qp_backing_plan plan,
    rdma_queue_backing_role_e role
  );
    rdma_qp_backing_ref backing_ref;

    if (plan == null)
      return 1'b0;
    if (plan.rq_source_h != null &&
        role inside {RDMA_QUEUE_ROLE_QP_RQ_RING,
                     RDMA_QUEUE_ROLE_QP_RQ_PD})
      return 1'b1;
    backing_ref = qp_plan_ref(plan, role);
    return backing_ref == null ||
           backing_ref.ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
           backing_ref.cleanup_complete;
  endfunction

  // 功能：qp_cleanup_predecessors_complete 比较 plan、role 与当前 authority/状态字段，返回布尔结果供上层执行精确分支。
  // 输入/输出及副作用：plan（输入）、role（输入）；qp_cleanup_predecessors_complete 读取 plan、role 并使用字段 urc_dsq_complete、urc_rdsq_complete、urc_rsq_complete、rq_pd_complete、sq_pd_complete、rq_ring_complete；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：qp_cleanup_predecessors_complete 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function bit qp_cleanup_predecessors_complete(
    rdma_qp_backing_plan plan,
    rdma_queue_backing_role_e role
  );
    bit urc_dsq_complete;
    bit urc_rdsq_complete;
    bit urc_rsq_complete;
    bit rq_pd_complete;
    bit sq_pd_complete;
    bit rq_ring_complete;

    urc_dsq_complete = qp_owned_cleanup_role_complete(
      plan, RDMA_QUEUE_ROLE_QP_URC_DSQ
    );
    urc_rdsq_complete = qp_owned_cleanup_role_complete(
      plan, RDMA_QUEUE_ROLE_QP_URC_RDSQ
    );
    urc_rsq_complete = qp_owned_cleanup_role_complete(
      plan, RDMA_QUEUE_ROLE_QP_URC_RSQ
    );
    rq_pd_complete = qp_owned_cleanup_role_complete(
      plan, RDMA_QUEUE_ROLE_QP_RQ_PD
    );
    sq_pd_complete = qp_owned_cleanup_role_complete(
      plan, RDMA_QUEUE_ROLE_QP_SQ_PD
    );
    rq_ring_complete = qp_owned_cleanup_role_complete(
      plan, RDMA_QUEUE_ROLE_QP_RQ_RING
    );
    case (role)
      RDMA_QUEUE_ROLE_QP_URC_DSQ:
        return 1'b1;
      RDMA_QUEUE_ROLE_QP_URC_RDSQ:
        return urc_dsq_complete;
      RDMA_QUEUE_ROLE_QP_URC_RSQ:
        return urc_dsq_complete && urc_rdsq_complete;
      RDMA_QUEUE_ROLE_QP_RQ_PD:
        return urc_dsq_complete && urc_rdsq_complete && urc_rsq_complete;
      RDMA_QUEUE_ROLE_QP_SQ_PD:
        return urc_dsq_complete && urc_rdsq_complete && urc_rsq_complete &&
               rq_pd_complete;
      RDMA_QUEUE_ROLE_QP_RQ_RING:
        return urc_dsq_complete && urc_rdsq_complete && urc_rsq_complete &&
               rq_pd_complete && sq_pd_complete;
      RDMA_QUEUE_ROLE_QP_SQ_RING:
        return urc_dsq_complete && urc_rdsq_complete && urc_rsq_complete &&
               rq_pd_complete && sq_pd_complete && rq_ring_complete;
      RDMA_QUEUE_ROLE_QP_SQ_SGB:
        return urc_dsq_complete && urc_rdsq_complete && urc_rsq_complete &&
               rq_pd_complete && sq_pd_complete && rq_ring_complete;
      default:
        return 1'b0;
    endcase
  endfunction

  // 功能：commit_recovery_replacement 将已经完成外部 projection 与业务 authority 校验的
  //   recovery record 在短 mutation guard 窗口内一次性写回，并用 epoch/source 证据阻断旧快照。
  // 输入/输出及副作用：key、replacement、source_record、epoch_snapshot、operation 为输入；
  //   成功时只更新 manager 自有 recovery_records[key] 并推进 publication_epoch，不调用
  //   factory/adapter，也不取得 recovery 中 mapping/backing 的外部所有权。
  // 失败/边界：key/record/source 缺失、replacement validate 返回 null/失败、epoch 过期、当前
  //   recovery 引用变化或 mutation_guard 忙时返回明确错误，且不写入部分记录；外部 projection
  //   必须在调用 helper 前完成。
  protected function rdma_status commit_recovery_replacement(
    string key,
    rdma_recovery_record replacement,
    rdma_recovery_record source_record,
    longint unsigned epoch_snapshot,
    string operation
  );
    rdma_status status;

    if (key == "" || replacement == null || source_record == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {operation, " recovery replacement is incomplete"}
      );
    if (mutation_guard == null || !mutation_guard.try_get(1))
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        {operation, " recovery commit window is busy"}
      );
    status = replacement.validate();
    if (status == null)
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " recovery replacement validation returned null"}
      );
    if (status.ok() && epoch_snapshot != publication_epoch)
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " recovery replacement is stale"}
      );
    if (status.ok() &&
        (!recovery_records.exists(key) ||
         recovery_records[key] != source_record))
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " recovery entry changed during projection"}
      );
    if (status.ok()) begin
      recovery_records[key] = replacement;
      advance_publication_epoch();
    end
    mutation_guard.put(1);
    return status;
  endfunction

  // 功能：clear_recovery_record 在 recovery 已完成硬件缺失证明后，以 source/epoch 证据和
  //   mutation guard 原子删除指定 recovery entry。
  // 输入/输出及副作用：key、source_record、epoch_snapshot、operation 为输入；成功时只删除
  //   manager 自有 recovery_records[key] 并推进 publication_epoch，不释放 recovery 中的
  //   外部 mapping/backing；其外部生命周期仍由调用方按 completion 契约处理。
  // 失败/边界：key/source 缺失、epoch 过期、entry 被替换或 guard 忙时返回明确错误；未知 key
  //   保持幂等成功，避免重复 clear 改变业务错误优先级。
  protected function rdma_status clear_recovery_record(
    string key,
    rdma_recovery_record source_record,
    longint unsigned epoch_snapshot,
    string operation
  );
    rdma_status status;

    if (!recovery_records.exists(key))
      return rdma_status::success();
    if (source_record == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, {operation, " recovery source is missing"}
      );
    if (mutation_guard == null || !mutation_guard.try_get(1))
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY, {operation, " recovery clear window is busy"}
      );
    status = rdma_status::success();
    if (epoch_snapshot != publication_epoch)
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE, {operation, " recovery clear is stale"}
      );
    else if (recovery_records[key] != source_record)
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE, {operation, " recovery entry changed during clear"}
      );
    if (status.ok()) begin
      recovery_records.delete(key);
      advance_publication_epoch();
    end
    mutation_guard.put(1);
    return status;
  endfunction

  // 功能：commit_resource_recovery_replacement 将 registry resource 与可选 recovery record
  //   作为同一份 detached candidate 提交，统一 ERROR transition、recovery replacement 和
  //   staged flag 的最终写回边界。
  // 输入/输出及副作用：key、replacement、recovery_replacement、source_resource、source_recovery、
  //   source_recovery_exists、epoch_snapshot、operation 为输入；replace_recovery/clear_recovery/
  //   clear_staged 选择 recovery/staged 的单向变化；成功时只更新 manager 自有账本并推进
  //   publication_epoch，不调用 factory/adapter，也不取得外部 backing 所有权。
  // 失败/边界：resource/recovery 缺失或 validate 返回 null/失败、key/handle identity 改变、
  //   epoch/source 过期、recovery presence 与 source 不符、replace/clear 同时置位或 guard 忙时
  //   返回明确错误；失败路径不留下 ERROR-only 或 recovery-only 半提交。
  protected function rdma_status commit_resource_recovery_replacement(
    string key,
    rdma_resource replacement,
    rdma_recovery_record recovery_replacement,
    bit replace_recovery,
    bit clear_recovery,
    bit clear_staged,
    rdma_resource source_resource,
    rdma_recovery_record source_recovery,
    bit source_recovery_exists,
    longint unsigned epoch_snapshot,
    string operation
  );
    rdma_status status;

    if (key == "" || replacement == null || replacement.handle == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {operation, " resource/recovery replacement is incomplete"}
      );
    if (replace_recovery && clear_recovery)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {operation, " recovery action is ambiguous"}
      );
    if (replace_recovery && recovery_replacement == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {operation, " recovery replacement is missing"}
      );
    if (source_resource == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " registry source is missing"}
      );
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " resource replacement validation returned null"}
      );
    if (!status.ok())
      return status;
    if (replace_recovery) begin
      status = recovery_replacement.validate();
      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          {operation, " recovery replacement validation returned null"}
        );
      if (!status.ok())
        return status;
    end
    if (mutation_guard == null || !mutation_guard.try_get(1))
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        {operation, " resource/recovery commit window is busy"}
      );
    status = rdma_status::success();
    if (epoch_snapshot != publication_epoch)
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE, {operation, " resource/recovery replacement is stale"}
      );
    else if (!registry.exists(key) || registry[key] != source_resource ||
             registry[key] == null || registry[key].handle == null ||
             !same_handle_instance(registry[key].handle, replacement.handle))
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " registry authority changed during projection"}
      );
    else if (source_recovery_exists != recovery_records.exists(key) ||
             source_recovery_exists && recovery_records[key] != source_recovery)
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " recovery authority changed during projection"}
      );
    if (status.ok()) begin
      registry[key] = replacement;
      if (replace_recovery)
        recovery_records[key] = recovery_replacement;
      else if (clear_recovery)
        recovery_records.delete(key);
      if (clear_staged)
        staged_allocations.delete(key);
      advance_publication_epoch();
    end
    mutation_guard.put(1);
    return status;
  endfunction

  // 功能：qp_progress_snapshots 为 QP flush/cleanup/context recovery 建立 detached 双账本
  //   快照，并冻结 publication epoch、registry source 和可选 recovery source，供后续 OCC commit。
  // 输入/输出及副作用：qp_h、operation 为输入；key、resource_copy、recovery_copy、
  //   has_recovery、epoch_snapshot、source_resource、source_recovery 为输出；函数只读取并
  //   投影 manager 账本，不取得外部 backing 所有权。
  // 失败/边界：目标不是 QP、状态不是 QUIESCING/ERROR、plan/recovery 缺失或 projection
  //   失败时返回对应错误，并清空所有 detached 输出；source 缺失时禁止进入 commit。
  protected function rdma_status qp_progress_snapshots(
    rdma_handle qp_h,
    string operation,
    output string key,
    output rdma_qp resource_copy,
    output rdma_recovery_record recovery_copy,
    output bit has_recovery,
    output longint unsigned epoch_snapshot,
    output rdma_resource source_resource,
    output rdma_recovery_record source_recovery
  );
    rdma_resource authoritative;
    rdma_resource projected;
    rdma_status status;

    key = "";
    resource_copy = null;
    recovery_copy = null;
    has_recovery = 1'b0;
    epoch_snapshot = '0;
    source_resource = null;
    source_recovery = null;
    status = lookup(qp_h, authoritative);
    if (!status.ok() || authoritative.handle.kind != RDMA_RESOURCE_QP)
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, {operation, " target is not a QP"}
      ) : status;
    key = resource_key(authoritative.handle);
    epoch_snapshot = publication_epoch;
    source_resource = registry[key];
    if (source_resource == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, {operation, " registry source is missing"}
      );
    if (!(registry[key].state inside {RDMA_RESOURCE_QUIESCING,
                                      RDMA_RESOURCE_ERROR}))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " requires QUIESCING or ERROR QP"}
      );
    status = project_resource_value(registry[key], {operation, " resource"},
                                    projected);
    if (!status.ok() || !$cast(resource_copy, projected) ||
        resource_copy.qp_plan == null)
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_STATE, {operation, " QP plan is missing"}
      ) : status;
    if (registry[key].state == RDMA_RESOURCE_ERROR) begin
      status = recovery_entry_schema_status(key, operation);
      if (!status.ok())
        return status;
      if (!recovery_records.exists(key) ||
          !recovery_records[key].qp_recovery_valid ||
          recovery_records[key].qp_recovery == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE, {operation, " QP recovery is missing"}
        );
      source_recovery = recovery_records[key];
      if (source_recovery == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE, {operation, " QP recovery source is missing"}
        );
      status = project_recovery_value(recovery_records[key],
                                      {operation, " recovery"}, recovery_copy);
      if (!status.ok())
        return status;
      has_recovery = 1'b1;
      if (!same_qp_plan_value(resource_copy.qp_plan,
                              recovery_copy.qp_recovery.qp_plan))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE, {operation, " recovery plan diverged"}
        );
    end
    return rdma_status::success();
  endfunction

  // 功能：commit_qp_progress 在一次 mutation guard 窗口内校验并同步发布 QP registry 与
  //   recovery 双账本进度，同时推进 publication epoch。
  // 输入/输出及副作用：key、resource_copy、recovery_copy、has_recovery、epoch_snapshot、
  //   source_resource、source_recovery、operation 为输入；成功时只更新 manager 自有账本，
  //   不取得外部 backing 所有权。
  // 失败/边界：guard 忙、快照/校验失败、epoch 过期或任一 source 引用变化时返回明确错误，
  //   保持 registry/recovery 原值，不推进游标、不留下半提交。
  protected function rdma_status commit_qp_progress(
    string key,
    rdma_qp resource_copy,
    rdma_recovery_record recovery_copy,
    bit has_recovery,
    longint unsigned epoch_snapshot,
    rdma_resource source_resource,
    rdma_recovery_record source_recovery,
    string operation
  );
    rdma_status status;

    if (mutation_guard == null || !mutation_guard.try_get(1))
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        {operation, " commit window is busy"}
      );
    status = resource_copy == null ? rdma_status::make(
      RDMA_SC_INVALID_STATE, {operation, " resource snapshot is null"}
    ) : resource_copy.validate();
    if (status == null)
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE, {operation, " resource validation returned null"}
      );
    if (status.ok() && source_resource == null)
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE, {operation, " registry source is missing"}
      );
    if (status.ok() && epoch_snapshot != publication_epoch)
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE, {operation, " QP progress candidate is stale"}
      );
    if (status.ok() &&
        (!registry.exists(key) || registry[key] != source_resource))
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " QP registry entry changed during projection"}
      );
    if (status.ok() && has_recovery) begin
      if (source_recovery == null || !recovery_records.exists(key) ||
          recovery_records[key] != source_recovery)
        status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          {operation, " QP recovery entry changed during projection"}
        );
    end
    if (status.ok() && has_recovery) begin
      status = recovery_copy.validate();
      if (status == null)
        status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          {operation, " recovery validation returned null"}
        );
    end
    if (status.ok()) begin
      registry[key] = resource_copy;
      if (has_recovery)
        recovery_records[key] = recovery_copy;
      advance_publication_epoch();
    end
    mutation_guard.put(1);
    return status;
  endfunction

  // 功能：在 rdma_resource_manager 中，record_qp_flush_complete 记录 record_qp_flush_complete 的调用名称和顺序，供测试断言转发路径；不改变被测事务业务结果。
  // 输入/输出及副作用：qp_h（输入）、role（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output
  //   返回结果。
  // 失败/边界：记录操作仅影响测试 trace；不得因注入记录故障改变生产状态或吞掉真实错误。
  virtual function rdma_status record_qp_flush_complete(
    rdma_handle qp_h,
    rdma_queue_backing_role_e role
  );
    rdma_qp resource_copy;
    rdma_recovery_record recovery_copy;
    rdma_qp_backing_plan recovery_plan;
    rdma_status status;
    bit has_recovery;
    bit already_complete;
    longint unsigned epoch_snapshot;
    rdma_resource source_resource;
    rdma_recovery_record source_recovery;
    string key;

    if (!(role inside {RDMA_QUEUE_ROLE_QP_SQ_RING,
                       RDMA_QUEUE_ROLE_QP_SQ_PD,
                       RDMA_QUEUE_ROLE_QP_RQ_PD}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP flush role is invalid");
    status = qp_progress_snapshots(qp_h, "QP flush progress", key,
                                   resource_copy, recovery_copy,
                                   has_recovery, epoch_snapshot,
                                   source_resource, source_recovery);
    if (!status.ok())
      return status;
    recovery_plan = has_recovery ? recovery_copy.qp_recovery.qp_plan : null;
    case (role)
      RDMA_QUEUE_ROLE_QP_SQ_RING: begin
        already_complete = resource_copy.qp_plan.cleanup_complete;
        if (!already_complete && has_recovery)
          already_complete = recovery_plan.cleanup_complete;
        if (!already_complete) begin
          resource_copy.qp_plan.cleanup_complete = 1'b1;
          if (has_recovery)
            recovery_plan.cleanup_complete = 1'b1;
        end
      end
      RDMA_QUEUE_ROLE_QP_SQ_PD: begin
        if (!resource_copy.qp_plan.cleanup_complete ||
            has_recovery && !recovery_plan.cleanup_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE, "QP QPN flush predecessor is incomplete"
          );
        already_complete = resource_copy.qp_plan.sq_pd_flush_complete;
        if (!already_complete && has_recovery)
          already_complete = recovery_plan.sq_pd_flush_complete;
        if (!already_complete) begin
          resource_copy.qp_plan.sq_pd_flush_complete = 1'b1;
          if (has_recovery)
            recovery_plan.sq_pd_flush_complete = 1'b1;
        end
      end
      RDMA_QUEUE_ROLE_QP_RQ_PD: begin
        if (resource_copy.qp_plan.rq_source_h != null)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT, "SRQ-backed QP has no private RQ flush"
          );
        if (!resource_copy.qp_plan.sq_pd_flush_complete ||
            has_recovery && !recovery_plan.sq_pd_flush_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE, "QP SQ PD flush predecessor is incomplete"
          );
        already_complete = resource_copy.qp_plan.rq_pd_flush_complete;
        if (!already_complete && has_recovery)
          already_complete = recovery_plan.rq_pd_flush_complete;
        if (!already_complete) begin
          resource_copy.qp_plan.rq_pd_flush_complete = 1'b1;
          if (has_recovery)
            recovery_plan.rq_pd_flush_complete = 1'b1;
        end
      end
    endcase
    if (already_complete)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP flush progress is already complete");
    return commit_qp_progress(key, resource_copy, recovery_copy, has_recovery,
                              epoch_snapshot, source_resource, source_recovery,
                              "QP flush progress");
  endfunction

  // 功能：在 rdma_resource_manager 中，record_qp_cleanup_complete 记录 record_qp_cleanup_complete 的调用名称和顺序，供测试断言转发路径；不改变被测事务业务结果。
  // 输入/输出及副作用：qp_h（输入）、role（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output
  //   返回结果。
  // 失败/边界：记录操作仅影响测试 trace；不得因注入记录故障改变生产状态或吞掉真实错误。
  virtual function rdma_status record_qp_cleanup_complete(
    rdma_handle qp_h,
    rdma_queue_backing_role_e role
  );
    rdma_qp resource_copy;
    rdma_recovery_record recovery_copy;
    rdma_qp_backing_ref resource_ref;
    rdma_qp_backing_ref recovery_ref;
    rdma_status status;
    bit has_recovery;
    bit release_complete;
    longint unsigned epoch_snapshot;
    rdma_resource source_resource;
    rdma_recovery_record source_recovery;
    string key;

    if (!rdma_qp_role_is_payload(role) && !rdma_qp_role_is_pd(role))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP cleanup role is invalid");
    status = qp_progress_snapshots(qp_h, "QP cleanup progress", key,
                                   resource_copy, recovery_copy,
                                   has_recovery, epoch_snapshot,
                                   source_resource, source_recovery);
    if (!status.ok())
      return status;
    resource_ref = qp_plan_ref(resource_copy.qp_plan, role);
    recovery_ref = has_recovery ?
      qp_plan_ref(recovery_copy.qp_recovery.qp_plan, role) : null;
    if (resource_ref == null ||
        resource_ref.ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
        resource_ref.cleanup_complete ||
        has_recovery && (recovery_ref == null ||
                         recovery_ref.cleanup_complete))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP cleanup role is absent, borrowed, or already complete"
      );
    if (!qp_cleanup_predecessors_complete(resource_copy.qp_plan, role) ||
        has_recovery && !qp_cleanup_predecessors_complete(
          recovery_copy.qp_recovery.qp_plan, role
        ))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP owned backing cleanup predecessor is incomplete"
      );
    if ((resource_copy.qp_plan.context_ref != null &&
         !resource_copy.qp_plan.context_ref.release_complete) ||
        has_recovery &&
          ((recovery_copy.qp_recovery.context_ref != null &&
            !recovery_copy.qp_recovery.context_ref.release_complete) ||
           (recovery_copy.qp_recovery.qp_plan.context_ref != null &&
            !recovery_copy.qp_recovery.qp_plan.context_ref.release_complete)))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP context cleanup must precede owned backing cleanup"
      );
    status = resource_ref.recovery_only ?
      query_qp_recovery_release_completion(resource_ref.mapping,
                                           release_complete) :
      query_owned_release_completion(resource_ref.mapping,
                                     release_complete);
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP backing completion query returned null"
      ) : status;
    if (!release_complete)
      return rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED,
        "QP backing release is not opaquely complete"
      );
    if (has_recovery) begin
      status = recovery_ref.recovery_only ?
        query_qp_recovery_release_completion(recovery_ref.mapping,
                                             release_complete) :
        query_owned_release_completion(recovery_ref.mapping,
                                       release_complete);
      if (status == null || !status.ok())
        return status == null ? rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "QP recovery backing completion query returned null"
        ) : status;
      if (!release_complete)
        return rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "QP recovery backing release is not opaquely complete"
        );
    end
    resource_ref.cleanup_complete = 1'b1;
    if (has_recovery) begin
      recovery_ref.cleanup_complete = 1'b1;
      recovery_copy.qp_recovery.role_complete[role] = 1'b1;
    end
    return commit_qp_progress(key, resource_copy, recovery_copy, has_recovery,
                              epoch_snapshot, source_resource, source_recovery,
                              "QP cleanup progress");
  endfunction

  // 功能：在 rdma_resource_manager 中，record_qp_context_cleanup_complete 记录 record_qp_context_cleanup_complete 的调用名称和顺序，供测试断言转发路径；不改变被测事务业务结果。
  // 输入/输出及副作用：qp_h（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：记录操作仅影响测试 trace；不得因注入记录故障改变生产状态或吞掉真实错误。
  virtual function rdma_status record_qp_context_cleanup_complete(
    rdma_handle qp_h
  );
    rdma_qp resource_copy;
    rdma_recovery_record recovery_copy;
    rdma_queue_slot_token_contract resource_token;
    rdma_queue_slot_token_contract recovery_token;
    rdma_status status;
    bit has_recovery;
    longint unsigned epoch_snapshot;
    rdma_resource source_resource;
    rdma_recovery_record source_recovery;
    string key;

    status = qp_progress_snapshots(qp_h, "QP context cleanup", key,
                                   resource_copy, recovery_copy,
                                   has_recovery, epoch_snapshot,
                                   source_resource, source_recovery);
    if (!status.ok())
      return status;
    if (resource_copy.qp_plan.context_ref == null &&
        (!has_recovery || recovery_copy.qp_recovery.context_ref == null))
      return rdma_status::success();
    if ((resource_copy.qp_plan.context_ref != null &&
         resource_copy.qp_plan.context_ref.release_complete) ||
        has_recovery &&
          ((recovery_copy.qp_recovery.context_ref != null &&
            recovery_copy.qp_recovery.context_ref.release_complete) ||
           (recovery_copy.qp_recovery.qp_plan.context_ref != null &&
            recovery_copy.qp_recovery.qp_plan.context_ref.release_complete)))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP context cleanup is absent or already complete"
      );
    if (!resource_copy.qp_plan.cleanup_complete ||
        !resource_copy.qp_plan.sq_pd_flush_complete ||
        resource_copy.qp_plan.rq_source_h == null &&
          !resource_copy.qp_plan.rq_pd_flush_complete ||
        has_recovery &&
          (!recovery_copy.qp_recovery.qp_plan.cleanup_complete ||
           !recovery_copy.qp_recovery.qp_plan.sq_pd_flush_complete ||
           recovery_copy.qp_recovery.qp_plan.rq_source_h == null &&
             !recovery_copy.qp_recovery.qp_plan.rq_pd_flush_complete))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP required flushes must precede context cleanup"
      );
    if (has_recovery &&
        (recovery_copy.qp_recovery.ambiguous_operation !=
           RDMA_QP_AMBIG_NONE ||
         recovery_copy.qp_recovery.ambiguous_ticket != null))
      return rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED,
        "QP recovery ambiguity must be resolved before context cleanup"
      );
    if (resource_copy.qp_plan.context_ref != null) begin
      if (!$cast(resource_token,
                 resource_copy.qp_plan.context_ref.slot_token) ||
          resource_token.completion_authority == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "QP context completion authority is invalid");
      if (!resource_token.completion_authority.complete)
        return rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                                 "QP context release is not opaquely complete");
    end
    if (has_recovery) begin
      if (recovery_copy.qp_recovery.context_ref != null) begin
        if (!$cast(recovery_token,
                   recovery_copy.qp_recovery.context_ref.slot_token) ||
            recovery_token.completion_authority == null ||
            resource_token.completion_authority == null ||
            recovery_token.completion_authority !==
              resource_token.completion_authority)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "QP recovery context completion authority changed");
        if (!recovery_token.completion_authority.complete)
          return rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                                   "QP recovery context release is not opaquely complete");
      end
    end
    resource_copy.qp_plan.context_ref.release_complete = 1'b1;
    if (has_recovery) begin
      recovery_copy.qp_recovery.context_ref.release_complete = 1'b1;
      recovery_copy.qp_recovery.qp_plan.context_ref.release_complete = 1'b1;
      recovery_copy.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
    end
    return commit_qp_progress(key, resource_copy, recovery_copy, has_recovery,
                              epoch_snapshot, source_resource, source_recovery,
                              "QP context cleanup");
  endfunction

  // 功能：qp_plan_cleanup_ready 比较 plan 与当前 authority/状态字段，返回布尔结果供上层执行精确分支。
  // 输入/输出及副作用：plan（输入）；qp_plan_cleanup_ready 读取 plan 并使用字段 status；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：qp_plan_cleanup_ready 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function bit qp_plan_cleanup_ready(rdma_qp_backing_plan plan);
    rdma_qp_backing_ref refs[$];
    rdma_queue_slot_token_contract token;
    rdma_status status;
    bit release_complete;

    if (plan == null)
      return 1'b0;
    // A partial pre-program plan may stop at any allocation.  Only require
    // flush/cleanup milestones for roles that actually have retained
    // authority; absent later roles are vacuously complete.
    if (plan.sq_ref != null && !plan.cleanup_complete)
      return 1'b0;
    if (plan.sq_pd_ref != null && !plan.sq_pd_flush_complete)
      return 1'b0;
    if (plan.rq_source_h == null && plan.rq_pd_ref != null &&
        !plan.rq_pd_flush_complete)
      return 1'b0;
    if (plan.context_ref != null) begin
      if (!plan.context_ref.release_complete ||
          !$cast(token, plan.context_ref.slot_token) ||
          token.completion_authority == null ||
          !token.completion_authority.complete)
        return 1'b0;
    end
    if (plan.sq_ref != null) refs.push_back(plan.sq_ref);
    if (plan.sq_sgb_ref != null) refs.push_back(plan.sq_sgb_ref);
    if (plan.sq_pd_ref != null) refs.push_back(plan.sq_pd_ref);
    if (plan.rq_source_h == null) begin
      if (plan.rq_ref != null) refs.push_back(plan.rq_ref);
      if (plan.rq_pd_ref != null) refs.push_back(plan.rq_pd_ref);
    end
    foreach (plan.urc_refs[i])
      refs.push_back(plan.urc_refs[i]);
    foreach (refs[i]) begin
      if (refs[i] == null)
        return 1'b0;
      if (refs[i].ownership == RDMA_OWNERSHIP_CONTROL_PLANE &&
          !refs[i].cleanup_complete)
        return 1'b0;
      if (refs[i].ownership == RDMA_OWNERSHIP_CONTROL_PLANE) begin
        status = refs[i].recovery_only ?
          query_qp_recovery_release_completion(refs[i].mapping,
                                               release_complete) :
          query_owned_release_completion(refs[i].mapping,
                                         release_complete);
        if (status == null || !status.ok() || !release_complete)
          return 1'b0;
      end
      if (refs[i].ownership == RDMA_OWNERSHIP_BORROWED &&
          refs[i].cleanup_complete)
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：finalize_qp_release 在空 QP reservation 或已完成 QP cleanup 后原子删除本地资源。
  // 输入/输出及副作用：qp_h 为 incarnation 键；admission 前冻结 epoch，检查 plan、context
  //   token、query/staging mapping 完成证明和依赖后，统一回收 registry/recovery/staged 与 QPN。
  // 失败/边界：非 QP、状态不允许、硬件未证明 ABSENT、plan/context/owned cleanup 未完成、
  //   依赖/outstanding、旧 epoch、重复 ID 或 guard 忙均拒绝；不替 adapter 释放外部 backing。
  virtual function rdma_status finalize_qp_release(rdma_handle qp_h);
    rdma_resource authoritative;
    rdma_qp authoritative_qp;
    rdma_recovery_record recovery;
    rdma_queue_slot_token_contract resource_context_token;
    rdma_queue_slot_token_contract recovery_context_token;
    rdma_queue_slot_token_contract recovery_plan_context_token;
    rdma_status status;
    bit release_complete;
    rdma_resource_activity_blocker_snapshot blockers;
    string key;
    longint unsigned epoch_snapshot;

    epoch_snapshot = publication_epoch;
    status = registry_schema_status("finalize QP release");
    if (!status.ok())
      return status;
    status = lookup(qp_h, authoritative);
    if (!status.ok() || !$cast(authoritative_qp, authoritative))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "QP finalization target is not a QP"
      ) : status;
    key = resource_key(authoritative.handle);
    if (registry[key].state == RDMA_RESOURCE_ALLOCATED &&
        authoritative_qp.qp_plan == null &&
        authoritative_qp.programmed_qpc == null) begin
      snapshot_activity_blockers(registry[key], blockers);
      if (blockers.has_live_dependents || blockers.has_outstanding_operations)
        return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                                 "QP reservation is still busy");
      return force_release_key(key, epoch_snapshot);
    end
    if (!(registry[key].state inside {RDMA_RESOURCE_QUIESCING,
                                      RDMA_RESOURCE_ERROR}))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP finalization requires QUIESCING, ERROR, or empty reservation"
      );
    if (!qp_plan_cleanup_ready(authoritative_qp.qp_plan))
      return rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED, "QP cleanup is not complete"
      );
    if (registry[key].state == RDMA_RESOURCE_ERROR) begin
      status = recovery_entry_schema_status(key, "finalize QP release");
      if (!status.ok())
        return status;
      if (!recovery_records.exists(key))
        return rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                                 "ERROR QP recovery is missing");
      recovery = recovery_records[key];
      if (recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT)
        return rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "ERROR QP hardware absence is not established"
        );
      if (recovery.qp_recovery == null ||
          recovery.qp_recovery.qp_plan == null)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "QP recovery plan authority is missing"
        );
      if (authoritative_qp.qp_plan.context_ref != null ||
          recovery.qp_recovery.context_ref != null ||
          recovery.qp_recovery.qp_plan.context_ref != null) begin
        if (authoritative_qp.qp_plan.context_ref == null ||
            recovery.qp_recovery.context_ref == null ||
            recovery.qp_recovery.qp_plan.context_ref == null ||
            !$cast(resource_context_token,
                   authoritative_qp.qp_plan.context_ref.slot_token) ||
            !$cast(recovery_context_token,
                   recovery.qp_recovery.context_ref.slot_token) ||
            !$cast(recovery_plan_context_token,
                   recovery.qp_recovery.qp_plan.context_ref.slot_token) ||
            resource_context_token.completion_authority == null ||
            recovery_context_token.completion_authority == null ||
            recovery_plan_context_token.completion_authority == null ||
            recovery_context_token.completion_authority !==
              resource_context_token.completion_authority ||
            recovery_plan_context_token.completion_authority !==
              resource_context_token.completion_authority)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "QP recovery context completion authority changed");
        if (!recovery_context_token.completion_authority.complete)
          return rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                                   "QP recovery context release is not opaquely complete");
      end
      if (!recovery.qp_recovery_valid || recovery.qp_recovery == null ||
          recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_NONE ||
          recovery.qp_recovery.ambiguous_ticket != null ||
          !qp_plan_cleanup_ready(recovery.qp_recovery.qp_plan) ||
          recovery.qp_recovery.context_ref != null &&
          !recovery.qp_recovery.context_ref.release_complete)
        return rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED, "QP recovery cleanup is not complete"
        );
      if (recovery.qp_recovery.staging_mapping != null) begin
        status = query_owned_release_completion(
          recovery.qp_recovery.staging_mapping, release_complete
        );
        if (status == null || !status.ok() || !release_complete)
          return rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            "QP recovery staging release is not complete"
          );
      end
      if (recovery.qp_recovery.query_mapping != null) begin
        status = recovery.qp_recovery.query_mapping_recovery_only ?
          query_qp_recovery_release_completion(
            recovery.qp_recovery.query_mapping, release_complete
          ) :
          query_owned_release_completion(
            recovery.qp_recovery.query_mapping, release_complete
          );
        if (status == null || !status.ok() || !release_complete)
          return rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            "QP recovery query release is not complete"
          );
      end
    end
    snapshot_activity_blockers(registry[key], blockers);
    if (blockers.has_live_dependents || blockers.has_outstanding_operations)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "QP still has live dependents or outstanding operations"
      );
    return force_release_key(key, epoch_snapshot);
  endfunction

  // 功能：在 rdma_resource_manager 中，queue_progress_snapshots 读取并封装队列/QP
  //   恢复进度的 detached candidate，使后续 role 检查和双快照提交使用同一组 key、
  //   resource 与 recovery 值。
  // 输入/输出及副作用：handle、operation 为输入，candidate 为输出；函数只投影
  //   registry/recovery_records 到 candidate，不写入两份账本、不取得外部资源所有权。
  // 失败/边界：队列不在 QUIESCING/ERROR、resource plan 缺失或校验返回 null/失败、
  //   ERROR 缺少 recovery、recovery schema/validate 失败时返回对应状态并清除 candidate；
  //   失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status queue_progress_snapshots(
    rdma_handle handle,
    string operation,
    output rdma_queue_progress_candidate candidate
  );
    rdma_resource authoritative;
    rdma_queue_resource queue_resource;
    rdma_status status;

    candidate = new("queue_progress_candidate");
    status = lookup(handle, authoritative);
    if (!status.ok()) begin
      candidate.clear();
      return status;
    end
    candidate.key = resource_key(authoritative.handle);
    // 在 detached projection 之前冻结 manager epoch 与 registry source 引用。
    // source 只是非拥有 OCC 证据；commit 会重新比较它，避免外部 factory/callback
    // 窗口内的新 publication 被旧 queue progress candidate 覆盖。
    candidate.manager_epoch = publication_epoch;
    candidate.source_resource = registry[candidate.key];
    if (candidate.source_resource == null) begin
      candidate.clear();
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "queue progress registry source is missing"
      );
    end
    if (!lifecycle_queue_kind(authoritative.handle.kind) ||
        !(registry[candidate.key].state inside {RDMA_RESOURCE_QUIESCING,
                                      RDMA_RESOURCE_ERROR}))
      begin
        candidate.clear();
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "queue progress requires QUIESCING or ERROR queue"
        );
      end
    status = project_resource_value(
      registry[candidate.key], {operation, " resource"},
      candidate.resource_copy
    );
    if (!status.ok() || !$cast(queue_resource, candidate.resource_copy) ||
        queue_resource.queue_plan == null)
      begin
        candidate.clear();
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_STATE, "queue progress resource plan is missing"
        ) : status;
      end
    status = queue_resource.queue_plan.validate();
    if (status == null) begin
      candidate.clear();
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "queue progress plan validation returned null"
      );
    end
    if (!status.ok()) begin
      candidate.clear();
      return status;
    end
    if (registry[candidate.key].state == RDMA_RESOURCE_ERROR) begin
      if (!recovery_records.exists(candidate.key)) begin
        candidate.clear();
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "ERROR queue has no recovery record"
        );
      end
      candidate.source_recovery = recovery_records[candidate.key];
      if (candidate.source_recovery == null) begin
        candidate.clear();
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "queue progress recovery source is missing"
        );
      end
      status = project_recovery_value(
        recovery_records[candidate.key], {operation, " recovery"},
        candidate.recovery_copy
      );
      if (!status.ok()) begin
        candidate.clear();
        return status;
      end
      if (candidate.recovery_copy == null ||
          !candidate.recovery_copy.queue_recovery_valid ||
          candidate.recovery_copy.queue_plan == null ||
          candidate.recovery_copy.queue_plan.resource_kind !=
            authoritative.handle.kind) begin
        candidate.clear();
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "ERROR queue recovery schema is incomplete"
        );
      end
      status = candidate.recovery_copy.validate();
      if (status == null) begin
        candidate.clear();
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "queue recovery validation returned null"
        );
      end
      if (!status.ok()) begin
        candidate.clear();
        return status;
      end
      candidate.has_recovery = 1'b1;
    end
    if (!candidate.valid()) begin
      candidate.clear();
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "queue progress candidate shape is incomplete"
      );
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_resource_manager 中，commit_queue_progress 校验并原子发布一个
  //   queue progress candidate，将 authoritative resource 与可选 ERROR recovery 快照
  //   同步写回各自账本。
  // 输入/输出及副作用：candidate、operation 为输入；函数读取 candidate 的 key、快照、
  //   manager_epoch 和 source 引用，成功时在同一 guard 窗口更新 registry/recovery_records
  //   并推进 publication_epoch，不接管外部 backing 所有权。
  // 失败/边界：mutation_guard 为空或已被其他最终提交占用时返回 RDMA_SC_RESOURCE_BUSY；
  //   candidate 为空/shape 不完整、resource 或 recovery validate 返回 null/失败时拒绝且不写入
  //   任一账本；epoch 过期或任一 source 引用变化同样拒绝写回；operation 仅用于保留
  //   调用方诊断上下文。
  protected function rdma_status commit_queue_progress(
    rdma_queue_progress_candidate candidate,
    string operation
  );
    rdma_status status;

    if (mutation_guard == null || !mutation_guard.try_get(1))
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        {operation, " commit window is busy"}
      );
    status = (candidate == null || !candidate.valid()) ?
      rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " queue progress candidate is incomplete"}
      ) : candidate.resource_copy.validate();
    if (status == null)
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "queue progress resource validation returned null"
      );
    if (status.ok() && candidate.source_resource == null)
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " queue progress source resource is missing"}
      );
    if (status.ok() && candidate.manager_epoch != publication_epoch)
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " queue progress candidate is stale"}
      );
    if (status.ok() &&
        (!registry.exists(candidate.key) ||
         registry[candidate.key] != candidate.source_resource))
      status = rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {operation, " queue progress resource changed during projection"}
      );
    if (status.ok() && candidate.has_recovery) begin
      if (candidate.source_recovery == null ||
          !recovery_records.exists(candidate.key) ||
          recovery_records[candidate.key] != candidate.source_recovery)
        status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          {operation, " queue progress recovery changed during projection"}
        );
    end
    if (status.ok() && candidate.has_recovery) begin
      status = candidate.recovery_copy.validate();
      if (status == null)
        status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "queue progress recovery validation returned null"
        );
    end
    // Both complete snapshots have passed validation; publish them together at
    // the single authoritative replacement point while holding mutation_guard.
    if (status.ok()) begin
      registry[candidate.key] = candidate.resource_copy;
      if (candidate.has_recovery)
        recovery_records[candidate.key] = candidate.recovery_copy;
      advance_publication_epoch();
    end
    mutation_guard.put(1);
    return status;
  endfunction

  // 设计：queue progress 的 role 是逻辑身份，不是数组位置。调用方必须先
  //   证明某个快照中该 role 恰好出现一次，才能把返回的索引用于后续
  //   authority/完成位比较；这样 recovery 快照缺失或重复 role 时不会把
  //   未初始化的索引误用为数组下标。
  // 功能：queue_flush_role_count 只扫描给定 flush_targets，统计 role 的唯一性
  //   并在命中时输出其索引，供 flush 事务在字段解引用前建立安全前置条件。
  // 输入/输出及副作用：plan、role（输入）、target_index（输出）；函数读取
  //   plan.flush_targets 及每个 target.role，不修改 plan、registry、recovery_records
  //   或外部 backing；返回匹配 role 的数量。
  // 失败/边界：plan 为空或没有非空 target 时返回 0，并把 target_index 置 0；出现多个
  //   同 role target 时返回实际数量但索引只保留最后一次命中，调用方不得在返回值不等于
  //   1 时使用该索引。
  protected function int unsigned queue_flush_role_count(
    rdma_queue_backing_plan plan,
    rdma_queue_backing_role_e role,
    output int unsigned target_index
  );
    return rdma_queue_role_cardinality_policy::count_flush_targets(
      plan, role, target_index
    );
  endfunction

  // 功能：queue_ref_role_count 只扫描给定 backing refs，统计 role 的唯一性并在命中
  //   时输出其索引，供 cleanup 事务在 authority compare 前建立安全前置条件。
  // 输入/输出及副作用：plan、role（输入）、ref_index（输出）；函数读取 plan.refs
  //   及每个 ref.role，不修改 plan、registry、recovery_records 或外部 backing；返回
  //   匹配 role 的数量。
  // 失败/边界：plan 为空或没有非空 ref 时返回 0，并把 ref_index 置 0；出现多个同 role
  //   ref 时返回实际数量但索引只保留最后一次命中，调用方不得在返回值不等于 1 时使用该索引。
  protected function int unsigned queue_ref_role_count(
    rdma_queue_backing_plan plan,
    rdma_queue_backing_role_e role,
    output int unsigned ref_index
  );
    return rdma_queue_role_cardinality_policy::count_backing_refs(
      plan, role, ref_index
    );
  endfunction

  // 设计：flush progress 同时存在于 authoritative queue 和 ERROR recovery 两份
  //   detached plan；role 是两份快照之间的匹配键。先确认 authoritative role 恰好
  //   唯一，再读取 recovery target，最后以 commit_queue_progress 一次性发布，避免
  //   失败路径留下单侧 flush_complete。
  // 功能：record_queue_flush_complete 为指定 queue backing role 记录一次完成的
  //   flush，并按 plan 顺序验证所有前驱已完成；ERROR queue 还会核对 recovery
  //   target 的 PD mapping authority，成功后原子更新两份进度快照。
  // 输入/输出及副作用：handle、role（输入）；函数读取 queue registry/recovery 的
  //   detached 快照，成功时只提交对应 flush_targets[*].flush_complete 位并返回 OK，
  //   不取得外部 mapping 或 queue backing 的所有权。
  // 失败/边界：handle 不存在、queue 不在 QUIESCING/ERROR、plan/recovery schema
  //   无效时传播对应状态；authoritative role 缺失/重复/已完成返回 INVALID_ARGUMENT，
  //   recovery role 缺失/重复、authority 不同或任一前驱未完成返回 INVALID_STATE；任一
  //   拒绝分支都不发布 registry/recovery 的部分进度。
  virtual function rdma_status record_queue_flush_complete(
    rdma_handle handle,
    rdma_queue_backing_role_e role
  );
    rdma_queue_progress_candidate progress;
    rdma_queue_resource resource_queue;
    int unsigned role_count;
    int unsigned target_index;
    int unsigned recovery_role_count;
    int unsigned recovery_target_index;
    rdma_status status;

    status = queue_progress_snapshots(
      handle, "queue flush progress", progress
    );
    if (!status.ok()) return status;
    if (!$cast(resource_queue, progress.resource_copy))
      return rdma_status::make(RDMA_SC_INVALID_STATE, "queue resource cast failed");
    // Establish the authoritative snapshot's role cardinality before any
    // recovery comparison can dereference target_index.  A missing or
    // duplicated local role is an argument error and must not be masked by a
    // malformed recovery snapshot.
    role_count = queue_flush_role_count(resource_queue.queue_plan, role,
                                         target_index);
    if (role_count != 1)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "queue flush role is absent, duplicated, or complete"
      );
    recovery_role_count = 0;
    if (progress.has_recovery) begin
      recovery_role_count = queue_flush_role_count(
        progress.recovery_copy.queue_plan, role, recovery_target_index
      );
      if (recovery_role_count != 1 ||
          progress.recovery_copy.queue_plan.flush_targets[recovery_target_index].flush_complete ||
          progress.recovery_copy.queue_plan.flush_targets[recovery_target_index].pd_ref == null ||
          resource_queue.queue_plan.flush_targets[target_index].pd_ref == null ||
          !same_mapping_value(
            progress.recovery_copy.queue_plan.flush_targets[recovery_target_index].pd_ref.mapping,
            resource_queue.queue_plan.flush_targets[target_index].pd_ref.mapping
          ))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "recovery flush role authority diverged");
    end
    if (resource_queue.queue_plan.flush_targets[target_index].flush_complete)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue flush role is absent, duplicated, or complete");
    foreach (resource_queue.queue_plan.flush_targets[i]) begin
      int unsigned recovery_predecessor_count;

      if (i >= target_index)
        continue;
      if (!resource_queue.queue_plan.flush_targets[i].flush_complete)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "queue flush predecessor is incomplete");
      if (progress.has_recovery) begin
        recovery_predecessor_count = 0;
        foreach (progress.recovery_copy.queue_plan.flush_targets[j]) begin
          if (progress.recovery_copy.queue_plan.flush_targets[j] != null &&
              progress.recovery_copy.queue_plan.flush_targets[j].role ==
                resource_queue.queue_plan.flush_targets[i].role) begin
            recovery_predecessor_count++;
            if (!progress.recovery_copy.queue_plan.flush_targets[j].flush_complete)
              return rdma_status::make(
                RDMA_SC_INVALID_STATE,
                "recovery queue flush predecessor is incomplete"
              );
          end
        end
        if (recovery_predecessor_count != 1)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "recovery queue flush predecessor is absent or duplicated"
          );
      end
    end
    resource_queue.queue_plan.flush_targets[target_index].flush_complete = 1'b1;
    if (progress.has_recovery)
      progress.recovery_copy.queue_plan.flush_targets[recovery_target_index].flush_complete = 1'b1;
    return commit_queue_progress(progress, "queue flush progress");
  endfunction

  // 设计：cleanup progress 以 backing role 为逻辑身份，而非 refs 数组位置；ERROR
  //   recovery 必须与 authoritative ref 逐字段、逐 authority 对齐。先建立本地唯一
  //   ref 索引，再做 recovery compare，才能保证异常 role 不会解引用未初始化下标。
  // 功能：record_queue_cleanup_complete 为指定 queue backing role 记录 control-plane
  //   cleanup，校验 ownership、recovery authority 及 SRQ SGB 所需的 SRFQ flush 前置，
  //   成功后原子更新 authoritative/recovery 两份 cleanup_complete 位。
  // 输入/输出及副作用：handle、role（输入）；函数读取并投影 queue progress 快照，
  //   成功时通过 commit_queue_progress 发布对应 refs[*].cleanup_complete，未接管
  //   mapping、segment 或其他外部 backing 的生命周期。
  // 失败/边界：基础 queue/recovery 快照无效时传播其状态；authoritative role 缺失/重复、
  //   已清理或非 CONTROL_PLANE 返回 INVALID_ARGUMENT；recovery role/authority 不唯一、
  //   SRFQ flush 未完成或 predecessor 不满足返回 INVALID_STATE；所有拒绝均保持原
  //   registry/recovery progress 不变。
  virtual function rdma_status record_queue_cleanup_complete(
    rdma_handle handle,
    rdma_queue_backing_role_e role
  );
    rdma_queue_progress_candidate progress;
    rdma_queue_resource resource_queue;
    int unsigned role_count;
    int unsigned ref_index;
    int unsigned recovery_role_count;
    int unsigned recovery_ref_index;
    rdma_status status;
    int unsigned srfq_flush_count;
    int unsigned recovery_srfq_flush_count;
    bit srfq_flush_complete;
    bit recovery_srfq_flush_complete;

    status = queue_progress_snapshots(
      handle, "queue cleanup progress", progress
    );
    if (!status.ok()) return status;
    if (!$cast(resource_queue, progress.resource_copy))
      return rdma_status::make(RDMA_SC_INVALID_STATE, "queue resource cast failed");
    // Establish the authoritative snapshot's role cardinality before any
    // recovery comparison can dereference ref_index.  A missing or duplicated
    // local role remains an argument error and cannot be converted into a
    // recovery authority result by an uninitialized array index.
    role_count = queue_ref_role_count(resource_queue.queue_plan, role,
                                       ref_index);
    if (role_count != 1)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "queue cleanup role is not uniquely owned and pending"
      );
    recovery_role_count = 0;
    if (progress.has_recovery) begin
      recovery_role_count = queue_ref_role_count(
        progress.recovery_copy.queue_plan, role, recovery_ref_index
      );
      if (recovery_role_count != 1 ||
          progress.recovery_copy.queue_plan.refs[recovery_ref_index].cleanup_complete ||
          progress.recovery_copy.queue_plan.refs[recovery_ref_index].ownership !=
            RDMA_OWNERSHIP_CONTROL_PLANE ||
          !same_queue_backing_ref_value(
            progress.recovery_copy.queue_plan.refs[recovery_ref_index],
            resource_queue.queue_plan.refs[ref_index]
          ) ||
          !same_owned_queue_backing_ref_authority(
            resource_queue.queue_plan.refs[ref_index],
            progress.recovery_copy.queue_plan.refs[recovery_ref_index]
          ))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "recovery cleanup role authority diverged");
    end
    if (resource_queue.queue_plan.refs[ref_index].cleanup_complete ||
        resource_queue.queue_plan.refs[ref_index].ownership !=
          RDMA_OWNERSHIP_CONTROL_PLANE)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue cleanup role is not uniquely owned and pending");
    if (role == RDMA_QUEUE_ROLE_SRQ_SGB) begin
      srfq_flush_count = 0;
      srfq_flush_complete = 1'b0;
      foreach (resource_queue.queue_plan.flush_targets[i]) begin
        if (resource_queue.queue_plan.flush_targets[i] != null &&
            resource_queue.queue_plan.flush_targets[i].role ==
              RDMA_QUEUE_ROLE_SRFQ_PD) begin
          srfq_flush_count++;
          srfq_flush_complete =
            resource_queue.queue_plan.flush_targets[i].flush_complete;
        end
      end
      if (srfq_flush_count != 1 || !srfq_flush_complete)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "SRQ SGB cleanup requires authoritative SRFQ flush completion"
        );
      if (progress.has_recovery) begin
        recovery_srfq_flush_count = 0;
        recovery_srfq_flush_complete = 1'b0;
        foreach (progress.recovery_copy.queue_plan.flush_targets[i]) begin
          if (progress.recovery_copy.queue_plan.flush_targets[i] != null &&
              progress.recovery_copy.queue_plan.flush_targets[i].role ==
              RDMA_QUEUE_ROLE_SRFQ_PD) begin
            recovery_srfq_flush_count++;
            recovery_srfq_flush_complete =
              progress.recovery_copy.queue_plan.flush_targets[i].flush_complete;
          end
        end
        if (recovery_srfq_flush_count != 1 ||
            !recovery_srfq_flush_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "SRQ SGB cleanup requires recovery SRFQ flush completion"
          );
      end
    end
    resource_queue.queue_plan.refs[ref_index].cleanup_complete = 1'b1;
    if (progress.has_recovery)
      progress.recovery_copy.queue_plan.refs[recovery_ref_index].cleanup_complete = 1'b1;
    return commit_queue_progress(progress, "queue cleanup progress");
  endfunction

  // 功能：record_queue_context_cleanup_complete 为 QUIESCING/ERROR 的 CQ、SRQ、
  //   CEQ 或 AEQ queue 记录 context backing 的本地释放完成位；ERROR 路径同时
  //   证明 authoritative 与 recovery context authority 对齐，再以双快照提交进度。
  // 输入/输出及副作用：handle（输入）定位 queue registry；函数先读取 detached
  //   resource/recovery snapshot，再在两份 candidate 的 context_ref 上置位
  //   release_complete 并调用 commit_queue_progress；成功返回 OK，不取得 context、
  //   HMC 或外部 backing 的生命周期所有权。
  // 失败/边界：handle 不存在、queue 状态/plan 无效、authoritative context 缺失或已
  //   完成返回 INVALID_ARGUMENT/INVALID_STATE；ERROR recovery context presence、
  //   slot-token、completion_authority、owner/resource定位、shadow/HMC 值不一致或
  //   任一 release_complete 已置位时拒绝，且所有拒绝均在 commit 前保持 registry 与
  //   recovery progress 不变。
  virtual function rdma_status record_queue_context_cleanup_complete(
    rdma_handle handle
  );
    rdma_queue_progress_candidate progress;
    rdma_queue_resource resource_queue;
    rdma_context_backing_ref recovery_context;
    rdma_status status;

    status = queue_progress_snapshots(
      handle, "queue context progress", progress
    );
    if (!status.ok()) return status;
    if (!$cast(resource_queue, progress.resource_copy) ||
        resource_queue.queue_plan == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "queue resource plan is unavailable"
      );
    recovery_context = null;
    if (progress.has_recovery && progress.recovery_copy != null &&
        progress.recovery_copy.queue_plan != null)
      recovery_context = progress.recovery_copy.queue_plan.context_ref;
    status = queue_context_progress_authority_status(
      resource_queue.queue_plan.context_ref,
      recovery_context,
      progress.has_recovery
    );
    if (!status.ok()) return status;
    // context release 是 queue cleanup recipe 的第一项本地动作，完成位必须
    // 独立记录；SRQ payload role 在本调用之后才释放，因此这里不能要求 SGB
    // progress，否则会倒置 recipe 顺序，或让已物理释放的 context 无法在 recovery
    // 中留下可重放的证据。
    resource_queue.queue_plan.context_ref.release_complete = 1'b1;
    if (progress.has_recovery) begin
      recovery_context.release_complete = 1'b1;
    end
    return commit_queue_progress(progress, "queue context progress");
  endfunction

  // Queue recovery metadata is retired immediately after the ACTIVE
  // replacement is published.  Keep a protected observation point at the
  // atomic boundary so derived managers can audit the prepared metadata
  // without extending its lifetime or changing publication ordering.
  // 功能：在 rdma_resource_manager 中，queue_restore_pre_publish_observer 读取或发布队列/QP 恢复进度快照，使恢复步骤可重复执行且不会重复释放资源。
  // 输入/输出及副作用：prepared_recovery（输入）；queue_restore_pre_publish_observer 读取 prepared_recovery 并使用输入参数和固定枚举/常量；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：queue_restore_pre_publish_observer 是抽象接口，完成、失败和资源回滚语义由实现类按本契约提供。
  protected virtual function void queue_restore_pre_publish_observer(
    rdma_recovery_record prepared_recovery
  );
  endfunction

  // This protected boundary observes detached queue replacements only.  It is
  // intentionally before their final validation and never exposes a live
  // registry or recovery-record object to the caller.
  // 功能：queue_restore_pre_validate_observer 校验 prepared_resource 与当前对象状态的一致性，返回 void 供上层决定是否提交。
  // 输入/输出及副作用：prepared_resource（输入）；queue_restore_pre_validate_observer 读取 prepared_resource 并使用输入参数和固定枚举/常量；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：queue_restore_pre_validate_observer 是抽象接口，完成、失败和资源回滚语义由实现类按本契约提供。
  protected virtual function void queue_restore_pre_validate_observer(
    rdma_resource prepared_resource
  );
  endfunction

  // 设计：MR 进入 ERROR 后只能在硬件仍存在、没有待执行破坏性步骤，且
  // registry 与 recovery 仍共享同一 backing/HMC authority 时恢复 ACTIVE。
  // opaque release query 只在这里读取 adapter 封存的完成事实；helper 不写
  // registry、recovery 或 mapping，调用方仍负责在成功后按原顺序发布状态。
  // 功能：mr_restore_authority_status 按 restore_active 原有拒绝顺序校验 MR ERROR
  // recovery 的硬件存在性、进度、backing/HMC cardinality、值 authority 及 owned
  // mapping 的 opaque release 状态，返回可供 caller 继续恢复 ACTIVE 的 status。
  // 输入/输出及副作用：authoritative（输入）是 registry 中仍由 manager 拥有的 MR
  // 快照，recovery（输入）是对应 ERROR recovery 记录；函数只读两份快照并通过
  // query_owned_release_completion 读取 adapter 封存完成证明，不修改 registry、
  // recovery、mapping 或外部资源所有权，返回 rdma_status。
  // 失败/边界：调用方必须先确认 key 存在、资源为 MR 且 recovery record 已登记；本
  // helper 保留原有拒绝顺序和错误文本，覆盖 null/硬件状态/待处理步骤、reference
  // cardinality、backing/HMC authority 变化以及 authoritative/recovery owned
  // backing 已释放等分支；opaque query 返回 null/失败或 complete 时按原错误拒绝。
  protected function rdma_status mr_restore_authority_status(
    rdma_resource authoritative,
    rdma_recovery_record recovery
  );
    rdma_status status;
    bit authoritative_release_complete;
    bit recovery_release_complete;

    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
        recovery.ambiguous_ticket != null ||
        recovery.pending_steps.size() != 0 ||
        !(recovery.completed_steps.size() == 0 ||
          (recovery.completed_steps.size() == 1 &&
           recovery.completed_steps[0] == RDMA_CTRL_STEP_HW_OCC_FLUSHED)))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "ERROR MR recovery is not safe to restore ACTIVE"
      );
    if (authoritative.backing_refs.size() != recovery.backing_refs.size() ||
        authoritative.hmc_refs.size() != recovery.hmc_refs.size())
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "ERROR MR recovery reference cardinality changed"
      );
    foreach (authoritative.backing_refs[i]) begin
      if (authoritative.backing_refs[i] == null ||
          recovery.backing_refs[i] == null ||
          authoritative.backing_refs[i].mapping == null ||
          recovery.backing_refs[i].mapping == null ||
          authoritative.backing_refs[i].ownership !=
            recovery.backing_refs[i].ownership ||
          authoritative.backing_refs[i].release_complete ||
          recovery.backing_refs[i].release_complete ||
          !same_mapping_value(
            authoritative.backing_refs[i].mapping,
            recovery.backing_refs[i].mapping
          ) ||
          authoritative.backing_refs[i].mapping.state != RDMA_MAPPING_ACTIVE)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "ERROR MR recovery backing authority changed"
        );
      if (authoritative.backing_refs[i].ownership ==
            RDMA_OWNERSHIP_CONTROL_PLANE) begin
        if (!same_owned_mapping_authority(
              authoritative.backing_refs[i].mapping,
              recovery.backing_refs[i].mapping
            ))
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "ERROR MR owned backing release authority changed"
          );
        status = query_owned_release_completion(
          authoritative.backing_refs[i].mapping,
          authoritative_release_complete
        );
        if (status == null || !status.ok() ||
            authoritative_release_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "ERROR MR authoritative owned backing was released"
          );
        status = query_owned_release_completion(
          recovery.backing_refs[i].mapping, recovery_release_complete
        );
        if (status == null || !status.ok() || recovery_release_complete)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "ERROR MR recovery owned backing was released"
          );
      end
    end
    foreach (authoritative.hmc_refs[i]) begin
      if (authoritative.hmc_refs[i] == null ||
          recovery.hmc_refs[i] == null ||
          !same_mapping_handle_value(
            authoritative.hmc_refs[i].owner,
            recovery.hmc_refs[i].owner
          ) ||
          authoritative.hmc_refs[i].object_kind !=
            recovery.hmc_refs[i].object_kind ||
          authoritative.hmc_refs[i].address != recovery.hmc_refs[i].address ||
          authoritative.hmc_refs[i].size != recovery.hmc_refs[i].size ||
          authoritative.hmc_refs[i].first_pbl_index !=
            recovery.hmc_refs[i].first_pbl_index ||
          authoritative.hmc_refs[i].index_valid !=
            recovery.hmc_refs[i].index_valid ||
          authoritative.hmc_refs[i].ownership != recovery.hmc_refs[i].ownership ||
          authoritative.hmc_refs[i].release_complete ||
          recovery.hmc_refs[i].release_complete)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "ERROR MR recovery HMC authority changed"
        );
    end
    return rdma_status::success();
  endfunction

  // 设计：queue 进入 ERROR 后只能在硬件仍存在、没有本地破坏性 cleanup，且
  // registry 与 recovery 仍共享同一 queue backing/context authority 时恢复 ACTIVE。
  // 该 helper 只做 recovery/authoritative plan 的只读证明；replacement 投影、SRQ
  // flush-bit reset、validate 与 registry/recovery 发布仍由 restore_active 按原顺序负责。
  // 功能：queue_restore_authority_status 按 restore_active 原有拒绝顺序校验 lifecycle
  //   queue ERROR recovery 的 shape、backing role 唯一性、mapping/HMC authority 与
  //   control-plane-owned opaque release completion，返回可继续构造 replacement 的 status。
  // 输入/输出及副作用：authoritative（输入）是 registry 中仍由 manager 拥有的 queue
  //   快照，recovery（输入）是对应 ERROR recovery 记录；函数只读两份快照，并通过
  //   query_owned_release_completion 读取 adapter 封存完成证明，不修改 registry、
  //   recovery、queue plan、mapping 或外部资源所有权，也不写 SRQ flush progress。
  // 失败/边界：调用方必须先完成 staged/recovery-record 存在性门禁并传入 lifecycle
  //   queue；本 helper 依次保留 recovery presence/ambiguity/plan、destructive cleanup、
  //   authoritative plan shape、每个 backing role 的唯一匹配与 value/mapping 状态、
  //   owned backing/segment release proof 以及 context/HMC authority 的原错误文本和
  //   首错顺序；任一拒绝直接返回 INVALID_STATE，opaque query 为 null/失败或已完成
  //   时同样拒绝，成功只返回 rdma_status::success()。
  protected function rdma_status queue_restore_authority_status(
    rdma_resource authoritative,
    rdma_recovery_record recovery
  );
    rdma_queue_resource authoritative_queue;
    rdma_status status;
    bit destructive_cleanup;
    int unsigned recovery_ref_count;
    bit release_complete;

    if (recovery == null || !recovery.queue_recovery_valid ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
        recovery.ambiguous_ticket != null || recovery.queue_plan == null ||
        recovery.queue_plan.resource_kind != authoritative.handle.kind)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "ERROR queue recovery is not present and unambiguous"
      );
    destructive_cleanup = recovery.queue_plan.context_ref != null &&
                          recovery.queue_plan.context_ref.release_complete;
    foreach (recovery.queue_plan.refs[i]) begin
      if (recovery.queue_plan.refs[i] != null &&
          recovery.queue_plan.refs[i].cleanup_complete)
        destructive_cleanup = 1'b1;
    end
    if (destructive_cleanup)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "ERROR queue recovery includes destructive local cleanup"
      );
    if (!$cast(authoritative_queue, authoritative) ||
        authoritative_queue.queue_plan == null ||
        authoritative_queue.queue_plan.refs.size() !=
          recovery.queue_plan.refs.size() ||
        ((authoritative_queue.queue_plan.context_ref == null) !=
         (recovery.queue_plan.context_ref == null)))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "ERROR queue authoritative plan diverged from recovery"
      );
    foreach (authoritative_queue.queue_plan.refs[i]) begin
      recovery_ref_count = 0;
      foreach (recovery.queue_plan.refs[j]) begin
        if (recovery.queue_plan.refs[j] != null &&
            authoritative_queue.queue_plan.refs[i] != null &&
            recovery.queue_plan.refs[j].role ==
              authoritative_queue.queue_plan.refs[i].role) begin
          recovery_ref_count++;
          if (recovery.queue_plan.refs[j].cleanup_complete ||
              authoritative_queue.queue_plan.refs[i].cleanup_complete ||
              !same_queue_backing_ref_value(
                recovery.queue_plan.refs[j],
                authoritative_queue.queue_plan.refs[i]
              ) ||
              recovery.queue_plan.refs[j].mapping == null ||
              recovery.queue_plan.refs[j].mapping.state != RDMA_MAPPING_ACTIVE)
            return rdma_status::make(
              RDMA_SC_INVALID_STATE,
              "ERROR queue backing cleanup or authority changed"
            );
          if (recovery.queue_plan.refs[j].ownership ==
                RDMA_OWNERSHIP_CONTROL_PLANE) begin
            if (!same_owned_queue_backing_ref_authority(
                  authoritative_queue.queue_plan.refs[i],
                  recovery.queue_plan.refs[j]
                ))
              return rdma_status::make(
                RDMA_SC_INVALID_STATE,
                "ERROR queue owned backing release authority changed"
              );
            status = query_owned_release_completion(
              recovery.queue_plan.refs[j].mapping, release_complete
            );
            if (status == null || !status.ok() || release_complete)
              return rdma_status::make(
                RDMA_SC_INVALID_STATE,
                "ERROR queue recovery backing was released"
              );
            status = query_owned_release_completion(
              authoritative_queue.queue_plan.refs[i].mapping, release_complete
            );
            if (status == null || !status.ok() || release_complete)
              return rdma_status::make(
                RDMA_SC_INVALID_STATE,
                "ERROR queue authoritative backing was released"
              );
            foreach (recovery.queue_plan.refs[j].additional_segments[k]) begin
              if (recovery.queue_plan.refs[j].additional_segments[k] == null ||
                  authoritative_queue.queue_plan.refs[i].
                    additional_segments[k] == null ||
                  recovery.queue_plan.refs[j].additional_segments[k].mapping ==
                    null ||
                  authoritative_queue.queue_plan.refs[i].
                    additional_segments[k].mapping == null ||
                  recovery.queue_plan.refs[j].additional_segments[k].
                    mapping.state != RDMA_MAPPING_ACTIVE ||
                  authoritative_queue.queue_plan.refs[i].
                    additional_segments[k].mapping.state !=
                      RDMA_MAPPING_ACTIVE)
                return rdma_status::make(
                  RDMA_SC_INVALID_STATE,
                  "ERROR queue backing segment authority changed"
                );
              status = query_owned_release_completion(
                recovery.queue_plan.refs[j].additional_segments[k].mapping,
                release_complete
              );
              if (status == null || !status.ok() || release_complete)
                return rdma_status::make(
                  RDMA_SC_INVALID_STATE,
                  "ERROR queue recovery backing segment was released"
                );
              status = query_owned_release_completion(
                authoritative_queue.queue_plan.refs[i].
                  additional_segments[k].mapping,
                release_complete
              );
              if (status == null || !status.ok() || release_complete)
                return rdma_status::make(
                  RDMA_SC_INVALID_STATE,
                  "ERROR queue authoritative backing segment was released"
                );
            end
          end
        end
      end
      if (recovery_ref_count != 1)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ERROR queue backing role is not unique");
    end
    if (recovery.queue_plan.context_ref != null &&
        (recovery.queue_plan.context_ref.release_complete ||
         authoritative_queue.queue_plan.context_ref.release_complete ||
         recovery.queue_plan.context_ref.hmc_ref == null ||
         authoritative_queue.queue_plan.context_ref.hmc_ref == null ||
         recovery.queue_plan.context_ref.hmc_ref.release_complete ||
         authoritative_queue.queue_plan.context_ref.hmc_ref.release_complete ||
         recovery.queue_plan.context_ref.hmc_ref.address !=
           authoritative_queue.queue_plan.context_ref.hmc_ref.address ||
         recovery.queue_plan.context_ref.hmc_ref.size !=
           authoritative_queue.queue_plan.context_ref.hmc_ref.size ||
         recovery.queue_plan.context_ref.hmc_ref.first_pbl_index !=
           authoritative_queue.queue_plan.context_ref.hmc_ref.first_pbl_index ||
         recovery.queue_plan.context_ref.hmc_ref.index_valid !=
           authoritative_queue.queue_plan.context_ref.hmc_ref.index_valid))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "ERROR queue context cleanup or authority changed"
      );
    return rdma_status::success();
  endfunction

  // 设计：SRQ 从 ERROR 或 QUIESCING 恢复时，旧 destroy 尝试可能只完成了部分 flush。
  // 只允许清理 detached recovery/resource candidate 上的进度位，registry 中的 authority
  // 必须等 candidate validate 成功后一次性替换，不能在 admission 阶段原地回退。
  // 功能：clear_srq_flush_progress 把 detached SRQ backing plan 的全部 flush target
  //   重置为未完成，使下一次 destroy 从同一组冻结 target 重新执行完整 flush 序列。
  // 输入/输出及副作用：plan（输入）为调用方拥有的 detached candidate；函数原地清零
  //   plan.flush_targets[*].flush_complete，不改 refs/context、registry、recovery_records 或外部 backing。
  // 失败/边界：调用方必须已证明 plan 与每个 flush target 非空且属于 SRQ candidate；
  //   本 void helper 不分配、不校验、不返回 status，空/畸形 graph 的拒绝仍由原 caller 顺序负责。
  protected function void clear_srq_flush_progress(
    rdma_queue_backing_plan plan
  );
    foreach (plan.flush_targets[i])
      plan.flush_targets[i].flush_complete = 1'b0;
  endfunction

  // 功能：restore_active 将安全的 QUIESCING 资源，或带完整 recovery authority 的 ERROR
  //   MR/lifecycle queue，恢复为新的 detached ACTIVE registry snapshot。
  // 输入/输出及副作用：handle（输入）是非拥有查找键；成功时以 replacement 覆盖
  //   registry[key]，ERROR 路径在同一 guard 中删除 recovery_records[key] 并推进 epoch；
  //   SRQ candidate 的 flush progress 被清零；不释放外部 mapping/backing。
  // 失败/边界：lookup/schema、staged allocation、MR/queue authority、projection/cast、
  //   candidate validate、状态或 epoch/source 门禁失败即拒绝；guard 忙返回 RESOURCE_BUSY。
  //   schema 可替换等值 recovery 快照，但拒绝不发布 ACTIVE 或删除恢复证据；
  //   非 MR/lifecycle queue 的 ERROR 资源被拒绝，observer 只接收候选快照。
  virtual function rdma_status restore_active(rdma_handle handle);
    rdma_resource authoritative;
    rdma_resource source_resource;
    rdma_resource replacement;
    rdma_recovery_record recovery;
    rdma_recovery_record recovery_replacement;
    rdma_recovery_record source_recovery;
    rdma_status status;
    longint unsigned epoch_snapshot;
    bit source_recovery_exists;
    string key;

    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    // lookup 不回写 registry；schema 只规范化 recovery。先冻结业务代际和 resource，
    // 再刷新规范化后的 recovery 引用，保证随后 authority/clone/observer 窗口均受 OCC 保护。
    epoch_snapshot = publication_epoch;
    source_resource = registry[key];
    source_recovery_exists = recovery_records.exists(key);
    source_recovery = source_recovery_exists ? recovery_records[key] : null;
    if (registry[key].state == RDMA_RESOURCE_ERROR) begin
      status = recovery_entry_schema_status(key, "restore active");
      if (!status.ok())
        return status;
      source_recovery_exists = recovery_records.exists(key);
      source_recovery = source_recovery_exists ? recovery_records[key] : null;
      if (authoritative.handle.kind == RDMA_RESOURCE_MR) begin
        if (staged_allocations.exists(key) || !recovery_records.exists(key))
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "ERROR restore requires an unstaged MR recovery record"
          );
        recovery = recovery_records[key];
        status = mr_restore_authority_status(registry[key], recovery);
        if (!status.ok())
          return status;
      end
      else if (lifecycle_queue_kind(authoritative.handle.kind)) begin
        if (staged_allocations.exists(key) || !recovery_records.exists(key))
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "ERROR queue restore requires an unstaged queue recovery record"
          );
        recovery = recovery_records[key];
        status = queue_restore_authority_status(registry[key], recovery);
        if (!status.ok())
          return status;
        status = project_recovery_value(recovery, "restore queue recovery",
                                        recovery_replacement);
        if (!status.ok() || recovery_replacement == null)
          return status.ok() ? rdma_status::make(
            RDMA_SC_INVALID_STATE, "ERROR queue recovery replacement is missing"
          ) : status;
        recovery_replacement.ambiguous_queue_operation = RDMA_QUEUE_AMBIG_NONE;
        recovery_replacement.ambiguous_role = RDMA_QUEUE_ROLE_CQ_RING;
        recovery_replacement.ambiguous_ticket = null;
        if (authoritative.handle.kind == RDMA_RESOURCE_SRQ)
          clear_srq_flush_progress(recovery_replacement.queue_plan);
        status = recovery_replacement.validate();
        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "restored queue recovery validation returned null"
          );
        if (!status.ok())
          return status;
      end
      else
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ERROR restore supports MR or lifecycle queue only");
    end
    else if (registry[key].state != RDMA_RESOURCE_QUIESCING)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "only QUIESCING or safe ERROR MR can be restored ACTIVE"
      );
    status = project_resource_value(registry[key], "restore active",
                                  replacement);
    if (!status.ok())
      return status;
    if (authoritative.state == RDMA_RESOURCE_ERROR &&
        lifecycle_queue_kind(authoritative.handle.kind)) begin
      rdma_queue_resource queue_replacement;
      rdma_queue_backing_plan restored_plan;

      if (!$cast(queue_replacement, replacement))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "restored queue resource type mismatch");
      status = project_queue_plan_value(recovery_replacement.queue_plan,
                                        "restore active queue plan",
                                        restored_plan);
      if (!status.ok() || restored_plan == null)
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_STATE, "restored queue plan is missing"
        ) : status;
      queue_replacement.queue_plan = restored_plan;
      if (authoritative.handle.kind == RDMA_RESOURCE_SRQ)
        clear_srq_flush_progress(queue_replacement.queue_plan);
      replacement = queue_replacement;
    end
    // A failed pre-delete SRQ flush may leave the first progress bit set;
    // restoring ACTIVE is permitted only for definitive no-change failures,
    // and must clear all pre-delete progress so the next destroy retries both
    // commands from a clean authority snapshot.
    if (authoritative.state == RDMA_RESOURCE_QUIESCING &&
        authoritative.handle.kind == RDMA_RESOURCE_SRQ) begin
      rdma_queue_resource queue_replacement;
      if (!$cast(queue_replacement, replacement) ||
          queue_replacement.queue_plan == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "restored SRQ plan is missing");
      clear_srq_flush_progress(queue_replacement.queue_plan);
      replacement = queue_replacement;
    end
    replacement.state = RDMA_RESOURCE_ACTIVE;
    if (authoritative.state == RDMA_RESOURCE_ERROR &&
        lifecycle_queue_kind(authoritative.handle.kind))
      queue_restore_pre_validate_observer(replacement);
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "restored resource validation returned null");
    if (!status.ok())
      return status;
    if (authoritative.state == RDMA_RESOURCE_ERROR &&
        lifecycle_queue_kind(authoritative.handle.kind))
      queue_restore_pre_publish_observer(recovery_replacement);
    return commit_resource_recovery_replacement(
      key,
      replacement,
      null,
      1'b0,
      authoritative.state == RDMA_RESOURCE_ERROR,
      1'b0,
      source_resource,
      source_recovery,
      source_recovery_exists,
      epoch_snapshot,
      "restore active"
    );
  endfunction

  // 设计：ERROR 重发布只接受可观察的 durable progress 变化；identity/authority 已由
  // caller 单独校验，因此这里不能把完整 recovery snapshot 比较误作资源等价判断。
  // 功能：same_queue_recovery_progress 比较 completed/pending step 序列、rollback
  //   cardinality，以及 queue refs/flush/context 的 cleanup completion 位，判断两份 ERROR
  //   snapshot 是否携带相同持久进度。
  // 输入/输出及副作用：lhs、rhs（输入）为只读 recovery 引用；返回 bit，不更新 registry、
  //   recovery_records、queue plan 或外部 adapter；rollback status 的内容刻意不参与比较。
  // 失败/边界：任一 recovery 为 null、step/rollback 数量或 step 内容不同、plan 单边为空、
  //   refs/flush 数量或 completion 位不同、嵌套 ref/target 单边为空、context presence/release
  //   不同均返回 0；两侧 plan 同时为 null 时在已比较 step cardinality 后返回 1。
  protected function bit same_queue_recovery_progress(
    rdma_recovery_record lhs,
    rdma_recovery_record rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    if (lhs.completed_steps.size() != rhs.completed_steps.size() ||
        lhs.pending_steps.size() != rhs.pending_steps.size() ||
        lhs.rollback_statuses.size() != rhs.rollback_statuses.size())
      return 1'b0;
    foreach (lhs.completed_steps[i])
      if (lhs.completed_steps[i] != rhs.completed_steps[i]) return 1'b0;
    foreach (lhs.pending_steps[i])
      if (lhs.pending_steps[i] != rhs.pending_steps[i]) return 1'b0;
    if (lhs.queue_plan == null || rhs.queue_plan == null)
      return lhs.queue_plan == rhs.queue_plan;
    if (lhs.queue_plan.refs.size() != rhs.queue_plan.refs.size() ||
        lhs.queue_plan.flush_targets.size() != rhs.queue_plan.flush_targets.size())
      return 1'b0;
    foreach (lhs.queue_plan.refs[i]) begin
      if (lhs.queue_plan.refs[i] == null || rhs.queue_plan.refs[i] == null ||
          lhs.queue_plan.refs[i].cleanup_complete !=
            rhs.queue_plan.refs[i].cleanup_complete)
        return 1'b0;
    end
    foreach (lhs.queue_plan.flush_targets[i]) begin
      if (lhs.queue_plan.flush_targets[i] == null ||
          rhs.queue_plan.flush_targets[i] == null ||
          lhs.queue_plan.flush_targets[i].flush_complete !=
            rhs.queue_plan.flush_targets[i].flush_complete)
        return 1'b0;
    end
    if ((lhs.queue_plan.context_ref == null) !=
        (rhs.queue_plan.context_ref == null)) return 1'b0;
    if (lhs.queue_plan.context_ref != null &&
        lhs.queue_plan.context_ref.release_complete !=
          rhs.queue_plan.context_ref.release_complete) return 1'b0;
    return 1'b1;
  endfunction

  // 功能：mark_error_transition 校验并合并 MR/queue 的恢复证据，将 ERROR resource、
  //   recovery record 与 staged 清除作为一次双账本提交，保留已证明的 queue cleanup 进度。
  // 输入/输出及副作用：handle 定位 incarnation，recovery 为 caller 候选；reserved_only
  //   限定未 staged 的 ALLOCATED MR 本地回滚。成功推进 publication_epoch，不做外部释放。
  // 失败/边界：QP、未知/畸形身份、恢复句柄不匹配、非 canonical reservation、owned 完成证明
  //   不符、queue plan/owner/role 错误或无进度重放均拒绝；投影/校验失败、epoch/source 变化
  //   或 guard 忙不发布 ERROR-only/recovery-only 半成品；保留 exact-old incarnation 恢复入口。
  protected function rdma_status mark_error_transition(
    rdma_handle handle,
    rdma_recovery_record recovery,
    bit reserved_only
  );
    rdma_resource source_resource;
    rdma_resource replacement;
    rdma_recovery_record recovery_copy;
    rdma_recovery_record source_recovery;
    rdma_function_handle related_owner;
    rdma_handle trusted_handle;
    rdma_status status;
    bit opaque_release_complete;
    bit backing_release_pending;
    bit source_recovery_exists;
    longint unsigned epoch_snapshot;
    string key;

    status = project_handle_value(handle, "mark error", trusted_handle);
    if (!status.ok())
      return status;
    if (trusted_handle != null &&
        trusted_handle.kind == RDMA_RESOURCE_QP)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP resources require QP-specific ERROR publication"
      );
    status = project_public_recovery_value(recovery, "mark error",
                                           recovery_copy);
    if (!status.ok())
      return status;
    if (trusted_handle == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "error resource handle is null");
    if (!valid_kind(trusted_handle.kind) ||
        (trusted_handle.kind != RDMA_RESOURCE_FUNCTION &&
         trusted_handle.object_id[31:28] != trusted_handle.kind))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "error resource handle is malformed");
    key = resource_key(trusted_handle);
    status = recovery_entry_schema_status(key, "mark error");
    if (!status.ok())
      return status;
    if (!registry.exists(key)) begin
      if (related_incarnation_owner(trusted_handle, related_owner))
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "error resource generation is stale");
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "error resource incarnation is unknown");
    end
    source_resource = registry[key];
    source_recovery_exists = recovery_records.exists(key);
    source_recovery = source_recovery_exists ? recovery_records[key] : null;
    epoch_snapshot = publication_epoch;
    status = project_resource_value(registry[key], "mark error registry",
                                    replacement);
    if (!status.ok())
      return status;
    if (replacement.handle == null ||
        !same_handle_instance(replacement.handle, trusted_handle))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "error registry identity is inconsistent");
    if (recovery_copy.resource_h == null ||
        !same_handle_instance(recovery_copy.resource_h, trusted_handle))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "recovery record does not match the resource incarnation"
      );
    status = recovery_copy.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "recovery validation returned null");
    if (!status.ok())
      return status;
    if (reserved_only) begin
      if (replacement.handle.kind != RDMA_RESOURCE_MR ||
          replacement.state != RDMA_RESOURCE_ALLOCATED ||
          staged_allocations.exists(key))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "reserved ERROR requires an unstaged ALLOCATED MR"
        );
      if (recovery_copy.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
          recovery_copy.ambiguous_ticket != null ||
          recovery_copy.hmc_refs.size() != 0 ||
          recovery_copy.pending_steps.size() != 1 ||
          !(recovery_copy.pending_steps[0] inside {
            RDMA_CTRL_STEP_BACKING_RELEASED,
            RDMA_CTRL_STEP_RESOURCE_RELEASED
          }) ||
          recovery_copy.backing_refs.size() != 1)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "reserved ERROR recovery is not canonical local cleanup"
        );
      backing_release_pending = recovery_copy.pending_steps[0] ==
        RDMA_CTRL_STEP_BACKING_RELEASED;
      foreach (recovery_copy.backing_refs[i]) begin
        if (recovery_copy.backing_refs[i] == null ||
            recovery_copy.backing_refs[i].ownership !=
              RDMA_OWNERSHIP_CONTROL_PLANE ||
            recovery_copy.backing_refs[i].mapping == null)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "reserved ERROR backing authority is incomplete"
          );
        status = query_owned_release_completion(
          recovery_copy.backing_refs[i].mapping, opaque_release_complete
        );
        if (status == null || !status.ok())
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "reserved ERROR backing completion proof is invalid"
          );
        if (backing_release_pending &&
            (recovery_copy.backing_refs[i].release_complete ||
             recovery_copy.backing_refs[i].mapping.state !=
               RDMA_MAPPING_ACTIVE || opaque_release_complete))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "reserved ERROR backing cleanup is not owned and live"
          );
        if (!backing_release_pending &&
            (!recovery_copy.backing_refs[i].release_complete ||
             recovery_copy.backing_refs[i].mapping.state !=
               RDMA_MAPPING_RELEASED || !opaque_release_complete))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "reserved ERROR resource cleanup lacks released backing"
          );
      end
    end
    else if (replacement.handle.kind == RDMA_RESOURCE_MR &&
             replacement.state == RDMA_RESOURCE_ALLOCATED &&
             !staged_allocations.exists(key)) begin
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "ALLOCATED MR requires staged key authority before ERROR"
      );
    end
    if (lifecycle_queue_kind(replacement.handle.kind)) begin
      rdma_queue_resource queue_replacement;
      rdma_queue_backing_plan authoritative_plan;
      rdma_queue_backing_plan recovery_plan;
      bit transaction_local_recovery;
      bit reservation_release_recovery;
      bit has_resource_release_step;

      if (!recovery_copy.queue_recovery_valid ||
          !$cast(queue_replacement, replacement))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue ERROR recovery lacks authoritative queue plan"
        );
      transaction_local_recovery = queue_replacement.queue_plan == null;
      reservation_release_recovery =
        canonical_queue_reservation_release_recovery(recovery_copy);
      if (reservation_release_recovery &&
          queue_replacement.state == RDMA_RESOURCE_ERROR &&
          recovery_records.exists(key) && recovery_records[key] != null &&
          same_queue_recovery_progress(recovery_records[key], recovery_copy))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ERROR recovery publication replay");
      has_resource_release_step = 1'b0;
      foreach (recovery_copy.pending_steps[i])
        if (recovery_copy.pending_steps[i] ==
              RDMA_CTRL_STEP_RESOURCE_RELEASED)
          has_resource_release_step = 1'b1;
      if (has_resource_release_step && !reservation_release_recovery)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "queue reservation release recovery is not canonical"
        );
      if (transaction_local_recovery) begin
        if (queue_replacement.state != RDMA_RESOURCE_ALLOCATED ||
            staged_allocations.exists(key) ||
            recovery_copy.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
            recovery_copy.queue_intent !=
              RDMA_QUEUE_RECOVER_CREATE_ROLLBACK ||
            recovery_copy.ambiguous_queue_operation != RDMA_QUEUE_AMBIG_NONE ||
            recovery_copy.ambiguous_ticket != null ||
            recovery_copy.pending_steps.size() != 1 ||
            !(recovery_copy.pending_steps[0] inside {
              RDMA_CTRL_STEP_BACKING_RELEASED,
              RDMA_CTRL_STEP_RESOURCE_RELEASED
            }) ||
            recovery_copy.queue_plan == null ||
            recovery_copy.queue_plan.resource_kind !=
              queue_replacement.resource_kind())
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "unstaged queue ERROR recovery is not canonical local rollback"
          );
        foreach (recovery_copy.completed_steps[i]) begin
          if (rdma_control_step_is_hardware(recovery_copy.completed_steps[i]))
            return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "unstaged queue ERROR recovery contains hardware history"
            );
        end
        foreach (recovery_copy.queue_plan.refs[i]) begin
          if (recovery_copy.queue_plan.refs[i] == null ||
              recovery_copy.queue_plan.refs[i].mapping == null ||
              !same_handle_instance(
                recovery_copy.queue_plan.refs[i].mapping.function_h,
                queue_replacement.owner
              ) ||
              (recovery_copy.queue_plan.refs[i].ownership ==
                 RDMA_OWNERSHIP_CONTROL_PLANE &&
               !same_handle_instance(
                 recovery_copy.queue_plan.refs[i].mapping.owner_h,
                 trusted_handle
               )))
            return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "unstaged queue ERROR backing owner is not authoritative"
            );
          foreach (recovery_copy.queue_plan.refs[i].additional_segments[j]) begin
            if (recovery_copy.queue_plan.refs[i].additional_segments[j] == null ||
                recovery_copy.queue_plan.refs[i].additional_segments[j].mapping ==
                  null ||
                !same_handle_instance(
                  recovery_copy.queue_plan.refs[i].additional_segments[j].
                    mapping.function_h,
                  queue_replacement.owner
                ) ||
                (recovery_copy.queue_plan.refs[i].additional_segments[j].
                   ownership == RDMA_OWNERSHIP_CONTROL_PLANE &&
                 !same_handle_instance(
                   recovery_copy.queue_plan.refs[i].additional_segments[j].
                     mapping.owner_h,
                   trusted_handle
                 )))
              return rdma_status::make(
                RDMA_SC_INVALID_ARGUMENT,
                "unstaged queue ERROR segment owner is not authoritative"
              );
          end
        end
        if (recovery_copy.queue_plan.context_ref != null &&
            !same_handle_instance(
              recovery_copy.queue_plan.context_ref.owner,
              queue_replacement.owner
            ))
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "unstaged queue ERROR context owner is not authoritative"
          );
        if (reservation_release_recovery) begin
          status = queue_local_release_plan_status(recovery_copy.queue_plan);
          if (!status.ok()) return status;
        end
        status = project_queue_plan_value(
          recovery_copy.queue_plan, "mark error transaction resource plan",
          authoritative_plan
        );
        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "transaction resource plan projection returned null"
          );
        if (!status.ok()) return status;
        status = project_queue_plan_value(
          recovery_copy.queue_plan, "mark error transaction recovery plan",
          recovery_plan
        );
        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "transaction recovery plan projection returned null"
          );
        if (!status.ok()) return status;
        queue_replacement.queue_plan = authoritative_plan;
        queue_replacement.depth = authoritative_plan.rings[0].depth;
        recovery_copy.queue_plan = recovery_plan;
        replacement = queue_replacement;
      end
      else if (reservation_release_recovery) begin
        // A reservation-only queue rollback is first persisted while the
        // resource is ALLOCATED, then may be retried after mark_error()
        // published the durable ERROR record.  Keep accepting the canonical
        // snapshot in that ERROR state so a subsequent recovery invocation
        // can atomically consume RESOURCE_RELEASED; rejecting it here would
        // strand a successfully cleaned-up ambiguous create forever.
        if (queue_replacement.state != RDMA_RESOURCE_ALLOCATED &&
            !(queue_replacement.state == RDMA_RESOURCE_ERROR &&
              recovery_records.exists(key)))
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "queue reservation recovery requires ALLOCATED or ERROR authority"
          );
        status = queue_reservation_release_plan_status(
          queue_replacement.queue_plan, recovery_copy.queue_plan
        );
        if (!status.ok()) return status;
        status = project_queue_plan_value(
          recovery_copy.queue_plan,
          "mark error reservation resource plan", authoritative_plan
        );
        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "reservation resource plan projection returned null"
          );
        if (!status.ok()) return status;
        status = project_queue_plan_value(
          recovery_copy.queue_plan,
          "mark error reservation recovery plan", recovery_plan
        );
        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "reservation recovery plan projection returned null"
          );
        if (!status.ok()) return status;
        queue_replacement.queue_plan = authoritative_plan;
        queue_replacement.depth = authoritative_plan.rings[0].depth;
        recovery_copy.queue_plan = recovery_plan;
        replacement = queue_replacement;
      end
      else begin
        // A QUIESCING progress record lives only in the registry.  Make that
        // snapshot authoritative when ERROR recovery begins so callers cannot
        // erase already-proven cleanup by supplying an older plan.
        status = project_queue_plan_value(
          queue_replacement.queue_plan,
          "mark error authoritative queue plan", authoritative_plan
        );
        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "queue ERROR plan projection returned null"
          );
        if (!status.ok()) return status;
        recovery_copy.queue_plan = authoritative_plan;
      end
      status = recovery_copy.validate();
      if (status == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "merged queue recovery validation returned null");
      if (!status.ok()) return status;
    end
    replacement.state = RDMA_RESOURCE_ERROR;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "ERROR resource validation returned null");
    if (!status.ok())
      return status;
    return commit_resource_recovery_replacement(
      key,
      replacement,
      recovery_copy,
      1'b1,
      1'b0,
      1'b1,
      source_resource,
      source_recovery,
      source_recovery_exists,
      epoch_snapshot,
      reserved_only ? "mark reserved error" : "mark error"
    );
  endfunction

  // 功能：mark_error 发布普通资源的 ERROR 和持久恢复证据，委托双账本 transition。
  // 输入/输出及副作用：handle、recovery 为输入；成功原子更新 registry/recovery 并清 staged。
  // 失败/边界：拒绝 QP、未 staged 的 ALLOCATED MR、错误 authority/plan、旧 snapshot 或锁忙；
  //   具体状态原样返回，不执行隐式恢复或释放。
  virtual function rdma_status mark_error(
    rdma_handle handle,
    rdma_recovery_record recovery
  );
    return mark_error_transition(handle, recovery, 1'b0);
  endfunction

  // 功能：mark_reserved_error 将尚未 staged 的 MR reservation 转为可重试的本地 ERROR。
  // 输入/输出及副作用：handle、recovery 为输入；成功以双账本提交保留 backing cleanup 证据。
  // 失败/边界：非 ALLOCATED MR、已 staged、硬件非 ABSENT、ambiguous ticket/HMC、非单步
  //   本地 cleanup、owned seal/completion 不符、snapshot 过期或锁忙均拒绝且不半提交。
  virtual function rdma_status mark_reserved_error(
    rdma_handle handle,
    rdma_recovery_record recovery
  );
    return mark_error_transition(handle, recovery, 1'b1);
  endfunction

  // Completes only the no-hardware recovery shape created by
  // mark_reserved_error().  The control plane must release the retained
  // backing authority before invoking this atomic local transition.
  // 功能：complete_reserved_error 完成 mark_reserved_error 保留的 MR 本地 rollback，
  //   仅在 adapter seal 已证明 backing 释放后，原子删除资源和恢复记录并归还 MR local ID。
  // 输入/输出及副作用：handle 为 ERROR MR 键；在 schema/lookup/completion 外部窗口前冻结
  //   epoch，成功提交 manager 账本，不再次执行 backing 释放。
  // 失败/边界：非 unstaged ERROR MR、硬件历史/非 ABSENT、ticket/HMC、非单步本地 cleanup、
  //   非单个 owned backing、state/completion 不符、依赖/在途操作、旧 epoch 或锁忙均拒绝。
  virtual function rdma_status complete_reserved_error(
    rdma_handle handle
  );
    rdma_resource authoritative;
    rdma_recovery_record recovery;
    rdma_dma_mapping canonical_mapping;
    rdma_status status;
    bit backing_release_pending;
    bit release_complete;
    string key;
    longint unsigned epoch_snapshot;

    epoch_snapshot = publication_epoch;
    status = registry_schema_status("complete reserved error");
    if (!status.ok())
      return status;
    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    status = recovery_entry_schema_status(key, "complete reserved error");
    if (!status.ok())
      return status;
    if (authoritative.handle.kind != RDMA_RESOURCE_MR ||
        registry[key].state != RDMA_RESOURCE_ERROR ||
        staged_allocations.exists(key) || !recovery_records.exists(key))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "resource is not a reserved ERROR MR"
      );
    recovery = recovery_records[key];
    if (recovery != null) begin
      foreach (recovery.completed_steps[i]) begin
        if (rdma_control_step_is_hardware(recovery.completed_steps[i]))
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "reserved ERROR completion rejects hardware history"
          );
      end
    end
    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.ambiguous_ticket != null ||
        recovery.hmc_refs.size() != 0 ||
        recovery.pending_steps.size() != 1 ||
        !(recovery.pending_steps[0] inside {
          RDMA_CTRL_STEP_BACKING_RELEASED,
          RDMA_CTRL_STEP_RESOURCE_RELEASED
        }) ||
        recovery.backing_refs.size() != 1 ||
        recovery.backing_refs[0] == null ||
        recovery.backing_refs[0].ownership !=
          RDMA_OWNERSHIP_CONTROL_PLANE ||
        recovery.backing_refs[0].mapping == null)
      return rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED,
        "reserved ERROR MR still requires non-local recovery"
      );
    backing_release_pending = recovery.pending_steps[0] ==
      RDMA_CTRL_STEP_BACKING_RELEASED;
    if (backing_release_pending &&
        (recovery.backing_refs[0].release_complete ||
         recovery.backing_refs[0].mapping.state != RDMA_MAPPING_ACTIVE))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "reserved ERROR backing cleanup schema is invalid"
      );
    if (!backing_release_pending &&
        (!recovery.backing_refs[0].release_complete ||
         recovery.backing_refs[0].mapping.state != RDMA_MAPPING_RELEASED))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "reserved ERROR resource cleanup schema is invalid"
      );
    // Public RELEASED state is forgeable; completion is proven solely by the
    // adapter-sealed fact shared with the canonical recovery mapping.
    canonical_mapping = recovery.backing_refs[0].mapping;
    status = query_owned_release_completion(
      canonical_mapping, release_complete
    );
    if (status == null || !status.ok() || !release_complete)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "reserved ERROR backing release is not opaquely complete"
      );
    if (has_dependents(registry[key]) ||
        registry[key].outstanding_ids.size() != 0)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "reserved ERROR MR still has live dependents or operations"
      );
    return force_release_key(key, epoch_snapshot);
  endfunction

  // 功能：在 rdma_resource_manager 中，lookup_recovery 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：handle（输入）、recovery（输出）；lookup_recovery 读取 handle、recovery 并使用字段 recovery、status、key，并写入 recovery；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：lookup_recovery 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  virtual function rdma_status lookup_recovery(
    rdma_handle handle,
    output rdma_recovery_record recovery
  );
    rdma_resource authoritative;
    rdma_status status;
    string key;

    recovery = null;
    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    status = recovery_entry_schema_status(key, "recovery lookup");
    if (!status.ok())
      return status;
    if (!recovery_records.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "resource has no recovery record");
    return project_recovery_value(recovery_records[key], "lookup recovery",
                                recovery);
  endfunction

  // 功能：clear_recovery 在 ERROR 资源的硬件缺失和 pending 清空证明成立后删除恢复记录。
  // 输入/输出及副作用：handle 为资源键；冻结 source/epoch 后检查 recovery_ready，
  //   成功仅删除 recovery 并推进 epoch，不释放 registry、ID 或外部 backing。
  // 失败/边界：lookup/schema 失败、非 ERROR、无 recovery、恢复未就绪、旧 source/epoch
  //   或 guard 忙均返回错误，保留恢复证据；公开入口重复 clear 返回 INVALID_STATE。
  virtual function rdma_status clear_recovery(rdma_handle handle);
    rdma_resource authoritative;
    rdma_recovery_record source_record;
    rdma_status status;
    longint unsigned epoch_snapshot;
    string key;

    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    status = recovery_entry_schema_status(key, "clear recovery");
    if (!status.ok())
      return status;
    if (registry[key].state != RDMA_RESOURCE_ERROR)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "only ERROR resource recovery can be cleared");
    if (!recovery_records.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "resource has no recovery record");
    source_record = recovery_records[key];
    epoch_snapshot = publication_epoch;
    if (!recovery_ready(recovery_records[key]))
      return rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED,
        "recovery cannot be cleared before hardware absence is proven"
      );
    return clear_recovery_record(
      key, source_record, epoch_snapshot, "clear recovery"
    );
  endfunction

  // 功能：finalize_release 为 QUIESCING 或恢复就绪的 ERROR 普通资源执行最终本地释放。
  // 输入/输出及副作用：handle 指定 incarnation；admission 前冻结 epoch，成功原子删除
  //   registry/recovery/staged、归还 local ID 并推进代际，不接管外部 backing。
  // 失败/边界：Function/QP 必须走专用入口；非 closing 状态、ERROR recovery 未就绪、
  //   依赖/outstanding、schema/lookup 失败、epoch 变化、重复 ID 或 guard 忙均不提交释放。
  virtual function rdma_status finalize_release(rdma_handle handle);
    rdma_resource authoritative;
    rdma_status status;
    rdma_resource_activity_blocker_snapshot blockers;
    string key;
    longint unsigned epoch_snapshot;

    epoch_snapshot = publication_epoch;
    status = registry_schema_status("finalize release");
    if (!status.ok())
      return status;
    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    status = recovery_entry_schema_status(key, "finalize release");
    if (!status.ok())
      return status;
    if (authoritative.handle.kind == RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function resources require privileged Function teardown"
      );
    if (authoritative.handle.kind == RDMA_RESOURCE_QP)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP resources require QP-specific finalization"
      );
    if (registry[key].state == RDMA_RESOURCE_ERROR) begin
      if (!recovery_records.exists(key) ||
          !recovery_ready(recovery_records[key]))
        return rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "ERROR resource still requires recovery"
        );
    end
    else if (registry[key].state != RDMA_RESOURCE_QUIESCING) begin
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "only QUIESCING or recovered ERROR resource can be finalized"
      );
    end
    snapshot_activity_blockers(registry[key], blockers);
    if (blockers.has_live_dependents)
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "resource still has live dependents");
    if (blockers.has_outstanding_operations)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "resource still has outstanding operations"
      );
    return force_release_key(key, epoch_snapshot);
  endfunction

  // 功能：release_reserved 回收 ALLOCATED reservation，或已完成 canonical queue
  //   reservation rollback 的 ERROR 资源，保留依赖优先于 outstanding 的 admission 顺序。
  // 输入/输出及副作用：handle 为资源键；admission 前冻结 epoch，成功原子清理 registry、
  //   recovery、staged 和 local-ID pool，不释放任何外部 mapping/backing。
  // 失败/边界：Function、有 plan/QPC 的 QP、非 ALLOCATED/合法 ERROR、缺少或不符 recovery、
  //   queue release authority 错误、依赖/outstanding、旧 epoch、ID 冲突或锁忙均拒绝。
  virtual function rdma_status release_reserved(rdma_handle handle);
    rdma_resource authoritative;
    rdma_qp authoritative_qp;
    rdma_queue_resource queue_resource;
    rdma_recovery_record recovery;
    rdma_status status;
    rdma_resource_activity_blocker_snapshot blockers;
    string key;
    longint unsigned epoch_snapshot;

    epoch_snapshot = publication_epoch;
    status = registry_schema_status("release reserved");
    if (!status.ok())
      return status;
    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    status = recovery_entry_schema_status(key, "release reserved");
    if (!status.ok())
      return status;
    if (authoritative.handle.kind == RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function resources require privileged Function teardown"
      );
    if (authoritative.handle.kind == RDMA_RESOURCE_QP &&
        ($cast(authoritative_qp, authoritative) &&
         (authoritative_qp.qp_plan != null ||
          authoritative_qp.programmed_qpc != null)))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP reservations require QP-specific finalization"
      );
    if (registry[key].state == RDMA_RESOURCE_ERROR) begin
      if (!recovery_records.exists(key))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "ERROR reservation has no recovery record"
        );
      recovery = recovery_records[key];
      if (!$cast(queue_resource, registry[key]) ||
          !canonical_queue_reservation_release_recovery(recovery))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "ERROR resource is not a queue reservation release recovery"
        );
      status = queue_reservation_release_plan_status(
        queue_resource.queue_plan, recovery.queue_plan
      );
      if (!status.ok()) return status;
      snapshot_activity_blockers(registry[key], blockers);
      if (blockers.has_live_dependents)
        return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                                 "resource still has live dependents");
      if (blockers.has_outstanding_operations)
        return rdma_status::make(
          RDMA_SC_RESOURCE_BUSY,
          "resource still has outstanding operations"
        );
      return force_release_key(key, epoch_snapshot);
    end
    if (registry[key].state != RDMA_RESOURCE_ALLOCATED)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "only an ALLOCATED reservation can be rolled back"
      );
    snapshot_activity_blockers(registry[key], blockers);
    if (blockers.has_live_dependents)
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "resource still has live dependents");
    if (blockers.has_outstanding_operations)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "resource still has outstanding operations"
      );
    return force_release_key(key, epoch_snapshot);
  endfunction

  // 功能：track_outstanding 在 ACTIVE resource 的 detached snapshot 中追加一个 outstanding
  //   operation ID，并通过 registry OCC helper 原子发布新的 ledger。
  // 输入/输出及副作用：handle、outstanding_id 为输入；成功时只更新 manager registry 并推进
  //   publication_epoch，不取得外部 operation 或 backing 所有权。
  // 失败/边界：ID 为零/重复、目标非 ACTIVE、projection/validate 失败、epoch/source 变化或
  //   mutation guard 忙时返回对应错误，原 outstanding ledger 保持不变。
  virtual function rdma_status track_outstanding(
    rdma_handle handle,
    longint unsigned outstanding_id
  );
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_status status;
    rdma_resource source_resource;
    longint unsigned epoch_snapshot;
    string key;

    if (outstanding_id == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "outstanding operation ID is zero");
    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    source_resource = registry[key];
    epoch_snapshot = publication_epoch;
    if (registry[key].state != RDMA_RESOURCE_ACTIVE)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "only ACTIVE resources accept outstanding operations"
      );
    foreach (registry[key].outstanding_ids[i]) begin
      if (registry[key].outstanding_ids[i] == outstanding_id)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "outstanding operation ID is already tracked"
        );
    end
    status = project_resource_value(registry[key], "track outstanding",
                                  replacement);
    if (!status.ok())
      return status;
    replacement.outstanding_ids.push_back(outstanding_id);
    return commit_registry_replacement(
      key, replacement, "track outstanding",
      epoch_snapshot, source_resource
    );
  endfunction

  // 功能：retire_outstanding 从 ACTIVE resource 的 detached outstanding ledger 删除一个已完成
  //   operation ID，并通过同一 registry OCC helper 原子发布结果。
  // 输入/输出及副作用：handle、outstanding_id 为输入；成功时只更新 manager registry 并推进
  //   publication_epoch，不释放或重新激活外部 operation。
  // 失败/边界：目标/ID 未知、projection/validate 失败、epoch/source 变化或 mutation guard
  //   忙时拒绝，原 ledger 保持不变。
  virtual function rdma_status retire_outstanding(
    rdma_handle handle,
    longint unsigned outstanding_id
  );
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_status status;
    rdma_resource source_resource;
    longint unsigned epoch_snapshot;
    string key;
    int found_index;

    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(authoritative.handle);
    source_resource = registry[key];
    epoch_snapshot = publication_epoch;
    found_index = -1;
    foreach (registry[key].outstanding_ids[i]) begin
      if (registry[key].outstanding_ids[i] == outstanding_id) begin
        found_index = i;
        break;
      end
    end
    if (found_index < 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "outstanding operation ID is not tracked"
      );
    status = project_resource_value(registry[key], "retire outstanding",
                                  replacement);
    if (!status.ok())
      return status;
    replacement.outstanding_ids.delete(found_index);
    return commit_registry_replacement(
      key, replacement, "retire outstanding",
      epoch_snapshot, source_resource
    );
  endfunction

  // 功能：在 rdma_resource_manager 中，freeze 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：handle（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：freeze 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  function rdma_status freeze(rdma_handle handle);
    rdma_resource candidate;
    rdma_status status;

    status = lookup(handle, candidate);
    if (!status.ok())
      return status;
    return commit_programmed(candidate);
  endfunction

  // 功能：release 兼容入口仅回收尚未编程且无依赖的 ALLOCATED 普通资源。
  // 输入/输出及副作用：handle 为资源键；schema/lookup 前冻结 epoch，成功原子移除资源及
  //   辅助账本、归还 local ID；保留 incarnation tombstone，外部 backing 由 caller 管理。
  // 失败/边界：Function、ERROR、非 ALLOCATED、仍有依赖、schema/lookup 失败、旧 epoch、
  //   ID 冲突或 guard 忙均拒绝；QP backing/context 仍应使用 QP 专用 finalization。
  function rdma_status \release (rdma_handle handle);
    rdma_resource ignored;
    rdma_status status;
    string key;
    longint unsigned epoch_snapshot;

    epoch_snapshot = publication_epoch;
    status = registry_schema_status("release");
    if (!status.ok())
      return status;
    status = lookup(handle, ignored);
    if (!status.ok())
      return status;
    key = resource_key(ignored.handle);
    status = recovery_entry_schema_status(key, "release");
    if (!status.ok())
      return status;
    if (ignored.handle.kind == RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function resources require privileged Function teardown"
      );
    if (ignored.handle.kind == RDMA_RESOURCE_QP)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP resources require QP-specific finalization"
      );
    if (registry[key].state == RDMA_RESOURCE_ERROR)
      return rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED,
        "ERROR resource requires recovery finalization"
      );
    if (registry[key].state != RDMA_RESOURCE_ALLOCATED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "frozen resource requires Function teardown");
    if (has_dependents(registry[key]))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "resource still has live dependents");
    return force_release_key(key, epoch_snapshot);
  endfunction

  // 功能：release_function 为精确 Function generation 计算依赖逆序 teardown 集合，
  //   一次提交所有资源的释放与 generation 退休，避免部分删除后才发现 allocator 冲突。
  // 输入/输出及副作用：owner 为非拥有 Function handle；成功删除所属 registry/recovery/
  //   staged、归还 local ID、标记 retired 并推进一次 epoch；保留 incarnation tombstone。
  // 失败/边界：空/错误 owner、未知身份/代际、已 retired、schema 失败、依赖环、epoch
  //   变化、ID 重复/越界或 guard 忙时拒绝；不调用外部硬件/backing 释放，caller 负责先静默。
  function rdma_status release_function(rdma_function_handle owner);
    bit selected[string];
    string release_order[$];
    string owner_key;
    string generation_key;
    int unsigned target_count;
    bit progress;
    bit blocked;
    rdma_function_handle trusted_owner;
    rdma_status status;
    longint unsigned epoch_snapshot;

    epoch_snapshot = publication_epoch;
    status = project_function_handle_value(owner, "Function teardown",
                                           trusted_owner);
    if (!status.ok())
      return status;
    if (trusted_owner == null ||
        trusted_owner.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function teardown handle is invalid");
    status = registry_schema_status("Function teardown");
    if (!status.ok())
      return status;
    status = recovery_schema_status("Function teardown");
    if (!status.ok())
      return status;
    owner_key = function_key(trusted_owner);
    generation_key = function_generation_key(trusted_owner);
    if (!binding_snapshots.exists(owner_key))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function teardown identity is unknown");
    refresh_generation(owner_key);
    if (retired_generations.exists(generation_key))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function generation is already retired");
    if (!known_generations.exists(generation_key))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function generation was never registered");

    target_count = 0;
    foreach (registry[key]) begin
      if (registry[key].owner != null &&
          same_handle_instance(registry[key].owner, trusted_owner))
        target_count++;
    end

    while (release_order.size() < target_count) begin
      progress = 1'b0;
      foreach (registry[key]) begin
        if (selected.exists(key) || registry[key].owner == null ||
            !same_handle_instance(registry[key].owner, trusted_owner))
          continue;
        blocked = 1'b0;
        foreach (registry[other_key]) begin
          if (key == other_key || selected.exists(other_key) ||
              registry[other_key].owner == null ||
              !same_handle_instance(registry[other_key].owner,
                                    trusted_owner))
            continue;
          if (resource_depends_on(registry[other_key],
                                  registry[key].handle))
            blocked = 1'b1;
          if (registry[key].handle.kind == RDMA_RESOURCE_FUNCTION &&
              registry[other_key].handle.kind !=
                RDMA_RESOURCE_FUNCTION)
            blocked = 1'b1;
        end
        if (!blocked) begin
          selected[key] = 1'b1;
          release_order.push_back(key);
          progress = 1'b1;
        end
      end
      if (!progress)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "resource dependency graph has a cycle");
    end

    return commit_resource_releases(
      release_order, epoch_snapshot, "Function teardown", generation_key
    );
  endfunction

  // 功能：check_leaks 校验 leak_count、null 与当前对象状态的一致性，并显式处理“leak filter”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：leak_count（输出）、null（输入）；check_leaks 读取 leak_count、owner 并使用字段 leak_count、trusted_owner、status，并写入 leak_count；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  function rdma_status check_leaks(
    output int unsigned leak_count,
    input rdma_function_handle owner = null
  );
    rdma_function_handle trusted_owner;
    rdma_status status;

    leak_count = 0;
    trusted_owner = null;
    if (owner != null) begin
      status = project_function_handle_value(owner, "leak filter",
                                             trusted_owner);
      if (!status.ok())
        return status;
      if (trusted_owner.kind != RDMA_RESOURCE_FUNCTION)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "leak filter is not a Function handle");
    end
    status = registry_schema_status("leak audit");
    if (!status.ok())
      return status;
    foreach (registry[key]) begin
      if (trusted_owner == null ||
          (registry[key].owner != null &&
           same_handle_instance(registry[key].owner, trusted_owner)))
        leak_count++;
    end
    if (leak_count != 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               $sformatf("%0d RDMA resources leaked",
                                         leak_count));
    return rdma_status::success();
  endfunction
endclass
