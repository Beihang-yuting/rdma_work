// 目录：核心执行层 core/rdma_resource_manager.sv。
// 职责：唯一拥有 resource registry、recovery、allocator、incarnation/generation 账本；
//   对外提供 detached 查询与资源生命周期提交，不执行 CMQ、DMA 或队列数据传输。
// 依赖：types/model 值契约、resource projector、transaction candidate、allocator/dependency policy。
//   projector 负责快照对象图与身份比较；本类仍唯一负责 admission、ledger 和 commit。
// 所有权与生命周期：manager 拥有账本快照，incarnation tombstone 释放后保留；
//   外部 mapping/backing 仅借用 adapter 的不透明 authority，不接管其生命周期。
// 设计：外部投影/完成证明在锁外；最终 mutation 在短 guard 内按冻结的 epoch/source 提交。
//   查询不隐式发布快照，避免重入读覆盖后来的 mutation。
//   普通生命周期在入口冻结 epoch，lookup/schema 完成后冻结 canonical source；
//   exact-old QP 在 fallback 投影前冻结 source。
//   reservation 补偿分独占回滚与过期返还：仅前者恢复游标/serial/binding，后者只归还
//   本次 local ID，不撤销窗口内其它分配。
//   binding 投影在锁外准备，首次登记与 ID/serial 消费在同一短提交完成，不留半登记 authority。

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

  // 功能：构造空 manager，publication_epoch=0，mutation_guard 为单 token。
  // 输入/输出及副作用：name 传给 UVM 父类；账本与 guard 均为空/初始状态。
  // 失败/边界：空账本不提供默认 Function authority，资源请求仍须通过 create_* 的 admission。
  function new(string name = "rdma_resource_manager");
    super.new(name);
    publication_epoch = '0;
    mutation_guard = new(1);
  endfunction

  // 功能：推进乐观并发代际，供 detached candidate 做 stage→commit 新鲜度校验。
  // 输入/输出及副作用：只更新 publication_epoch，不发布 registry 条目。
  // 失败/边界：到全一后饱和不回绕，避免旧 candidate 误判为新；仅在确认的 mutation 边界调用。
  protected function void advance_publication_epoch();
    if (publication_epoch != '1)
      publication_epoch++;
  endfunction

  // 功能：判断 kind 是否为 allocator policy 认可的资源类型。
  // 输入/输出及副作用：kind 输入；只读，返回 bit。
  // 失败/边界：无。
  protected function bit valid_kind(rdma_resource_kind_e kind);
    return rdma_resource_allocator_policy::valid_kind(kind);
  endfunction

  // 功能：判定 kind 是否由 queue backing plan 参与 QUIESCING/ERROR 恢复，供各分派共用。
  // 输入/输出及副作用：kind 输入；只读枚举，返回 bit。
  // 失败/边界：仅 CQ/SRQ/CEQ/AEQ 返回 1，其余含未定义值返回 0；范围窄于 valid_kind。
  protected function bit lifecycle_queue_kind(rdma_resource_kind_e kind);
    return kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                        RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ};
  endfunction

  // 功能：返回 kind 在 Function 内的 local ID 上限，供容量与越界检查。
  // 输入/输出及副作用：kind 输入；委托 allocator policy，只读。
  // 失败/边界：未列出的 kind 由 policy 的 default 分支处理。
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

  // 功能：按 function_uid:generation:kind:object_id 生成 registry 键。
  // 输入/输出及副作用：handle 输入；返回 string，只读。
  // 失败/边界：不校验空句柄，调用方须先校验，也不回退到 root0。
  protected function string resource_key(rdma_handle handle);
    return $sformatf("%016h:%08h:%01h:%08h", handle.function_uid,
                     handle.generation, handle.kind, handle.object_id);
  endfunction

  // 功能：生成 incarnation 账本键，与 resource_key 相同。
  // 输入/输出及副作用：handle 输入；返回 string，只读。
  // 失败/边界：调用方须先校验句柄。
  protected function string incarnation_key(rdma_handle handle);
    return resource_key(handle);
  endfunction

  // 功能：按 function_uid:object_id 生成 Function 键。
  // 输入/输出及副作用：owner 输入；返回 string，只读。
  // 失败/边界：调用方须先校验句柄。
  protected function string function_key(rdma_function_handle owner);
    return $sformatf("%016h:%08h", owner.function_uid, owner.object_id);
  endfunction

  // 功能：按 function_uid:object_id:generation 生成 Function 代际键。
  // 输入/输出及副作用：owner 输入；返回 string，只读。
  // 失败/边界：调用方须先校验句柄。
  protected function string function_generation_key(
    rdma_function_handle owner
  );
    return $sformatf("%016h:%08h:%08h", owner.function_uid,
                     owner.object_id, owner.generation);
  endfunction

  // 功能：按 Function 代际加 local_qpn 生成 QPC sequence 键。
  // 输入/输出及副作用：owner、local_qpn 输入；返回 string，只读。
  // 失败/边界：调用方须先校验句柄。
  protected function string qp_sequence_key(
    rdma_function_handle owner,
    int unsigned local_qpn
  );
    return $sformatf("%016h:%08h:%08h:%06h", owner.function_uid,
                     owner.object_id, owner.generation, local_qpn);
  endfunction

  // 功能：比较两个 HMC reference 的 owner、类型、地址、大小、PBLE 元数据、所有权和释放标志。
  // 输入/输出及副作用：lhs、rhs 只读，返回 bit；不修改任何对象。
  // 失败/边界：任一为空时返回 lhs==rhs；不比较 mapping state，调用方自行完成其余前置校验。
  protected function bit same_hmc_ref_value(
    rdma_hmc_ref lhs,
    rdma_hmc_ref rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return rdma_resource_projector::same_mapping_handle_value(lhs.owner, rhs.owner) &&
           lhs.object_kind == rhs.object_kind &&
           lhs.address.value == rhs.address.value &&
           lhs.size == rhs.size &&
           lhs.first_pbl_index == rhs.first_pbl_index &&
           lhs.index_valid == rhs.index_valid &&
           lhs.ownership == rhs.ownership &&
           lhs.release_complete == rhs.release_complete;
  endfunction

  // 设计：recovery-only mapping 的 state 可能被 adapter 改写（ACTIVE/RELEASED），
  //   故只比较 release authority 字段并忽略 state；完成性由 adapter query 另行证明。
  // 功能：比较 recovery projection 的完整 release authority，忽略公开 state。
  // 输入/输出及副作用：lhs、rhs 只读，返回 bit；不修改 mapping 或外部状态。
  // 失败/边界：两侧同为 null 返回 1，仅一侧为 null 或 authority 字段不一致返回 0。
  protected function bit same_recovery_mapping_value(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return rdma_resource_projector::same_mapping_release_fields(lhs, rhs);
  endfunction

  // 设计：公开字段相同不足以证明 recovery mapping 控制同一分配；
  //   用权威 mapping 的不透明 authority 快照让 recovery mapping 验证，并保持类型/值/别名防护。
  // 功能：判定 recovery mapping 是否接受权威 mapping 的 release authority。
  // 输入/输出及副作用：authoritative、recovery 只读，返回 bit；会调用 mapping 的快照/校验接口。
  // 失败/边界：任一为 null、投影失败、类型不一致或 hook 图被改动均返回 0。
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
    status = rdma_resource_projector::project_mapping_value(
      authoritative, "owned authority correspondence value", saved_value
    );
    if (status == null || !status.ok() || mapping_type == null)
      return 1'b0;
    status = authoritative.snapshot_release_authority(authority_snapshot);
    if (status == null || !status.ok() || authority_snapshot == null)
      return 1'b0;
    authority_type = authority_snapshot.get_object_type();
    status = rdma_resource_projector::project_mapping_value(
      authority_snapshot, "owned authority correspondence snapshot",
      saved_authority
    );
    if (status == null || !status.ok() || authority_type == null ||
        authority_type != mapping_type ||
        !rdma_resource_projector::owned_mapping_hook_graph_intact(
          authoritative, recovery, saved_value, mapping_type,
          authority_snapshot, saved_authority, authority_type
        ))
      return 1'b0;
    status = authoritative.release_authority_status(authority_snapshot);
    if (status == null || !status.ok() ||
        !rdma_resource_projector::owned_mapping_hook_graph_intact(
          authoritative, recovery, saved_value, mapping_type,
          authority_snapshot, saved_authority, authority_type
        ))
      return 1'b0;
    status = recovery.release_authority_status(authority_snapshot);
    return status != null && status.ok() &&
           rdma_resource_projector::owned_mapping_hook_graph_intact(
             authoritative, recovery, saved_value, mapping_type,
             authority_snapshot, saved_authority, authority_type
           );
  endfunction

  // 功能：比较 backing segment 的角色、所有权、映射范围、逻辑偏移和 mapping 值。
  // 输入/输出及副作用：lhs、rhs 只读，返回 bit。
  // 失败/边界：任一为 null（含同为 null）返回 0，保持空段拒绝语义。
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
           rdma_resource_projector::same_mapping_value(lhs.mapping, rhs.mapping);
  endfunction

  // 功能：比较 queue backing ref 的字段、mapping 及全部 additional segment。
  // 输入/输出及副作用：lhs、rhs 只读，返回 bit。
  // 失败/边界：同为 null 返回 1，仅一侧为 null 或任一字段/段不一致返回 0。
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
        !rdma_resource_projector::same_mapping_value(lhs.mapping, rhs.mapping))
      return 1'b0;
    foreach (lhs.additional_segments[i]) begin
      if (!same_backing_segment_value(lhs.additional_segments[i],
                                      rhs.additional_segments[i]))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：确认 recovery 的 control-plane backing 与权威 backing 的 release authority 对应。
  // 输入/输出及副作用：authoritative、recovery 只读，返回 bit。
  // 失败/边界：任一为空、ownership 非 CONTROL_PLANE、段数不同或任一 mapping authority 不对应返回 0。
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

  // 功能：比较 queue ring layout 的几何字段、初始极性及每页 mapping。
  // 输入/输出及副作用：lhs、rhs 只读，返回 bit。
  // 失败/边界：同为 null 返回 1，仅一侧为 null 或任一字段/页不一致返回 0。
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
          !rdma_resource_projector::same_mapping_value(lhs.pages[i].mapping, rhs.pages[i].mapping))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：比较两个 context backing 的 slot-token、completion authority、owner、定位和 HMC 值。
  // 输入/输出及副作用：lhs、rhs 只读，返回 bit；不写对象、账本或 adapter。
  // 失败/边界：同为空返回 1，单侧为空、$cast 失败、authority 缺失或不同实例、字段/HMC 不一致返回 0；
  //   不比较 backing 自身 release_complete，也不判断 completion_authority.complete。
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
        !rdma_resource_projector::same_handle_instance(lhs.owner, rhs.owner) ||
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

  // 设计：context cleanup 进度同时存在于 authoritative 快照与 ERROR recovery 快照；
  //   先证明两侧 presence 对称，再验证 completion authority 与 canonical 值，
  //   只读证明通过后 caller 才能在 detached candidate 上置位 release_complete 并提交。
  // 功能：为 context cleanup progress 建立 authoritative/recovery 两侧的只读 authority 前置条件。
  // 输入/输出及副作用：authoritative、recovery、has_recovery 输入；只读，返回 status，不修改任何状态。
  // 失败/边界：无 recovery 时 authoritative 为空/已完成/token 非法返回 INVALID_ARGUMENT；
  //   有 recovery 时 presence 不对称、recovery 已完成、token 非法或 authority 漂移返回 INVALID_STATE。
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

    // 先检查 presence parity：ERROR queue 的 recovery context 缺失属恢复状态破坏，
    // 不能伪造 context，也不能发布单侧进度。
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

  // 功能：判断 authoritative 与 candidate 是否可作为同一已释放的 context 恢复记录。
  // 输入/输出及副作用：authoritative、candidate 只读，返回 bit。
  // 失败/边界：同为空返回 1；authority 值不一致、candidate completion 未完成或未 release 返回 0。
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

  // 功能：判断 recovery 是否为规范的 queue reservation 创建回滚记录（仅待 RESOURCE_RELEASED）。
  // 输入/输出及副作用：recovery 只读，返回 bit。
  // 失败/边界：为空、硬件非 ABSENT、intent 非 CREATE_ROLLBACK、有歧义票据、无 plan、pending 步骤不唯一，
  //   或 BACKING_RELEASED 完成次数不为 1 时返回 0。
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

  // 功能：只读检查 borrowed queue backing 及其附加段仍可安全借用，先主体后逐段。
  // 输入/输出及副作用：backing 输入；backing_fields_intact 输出，仅返回 0 时区分主体失败(0)与附加段失败(1)。
  // 失败/边界：主体为空、非 BORROWED、cleanup 已完成、mapping 为空或非 ACTIVE 返回 0；
  //   任一附加段同类问题也返回 0；无附加段视为通过。
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

  // 功能：核对 control-plane owned backing 的全部附加段均已有释放完成证明。
  // 输入/输出及副作用：backing 输入；逐段调用 query_owned_release_completion，只读，返回 bit。
  // 失败/边界：backing 为空、非 CONTROL_PLANE、段为空、query 失败或未完成返回 0；无附加段返回 1。
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

  // 功能：校验 authoritative 与 candidate 的 queue reservation 释放计划一致，且 owned backing 已有完成证明。
  // 输入/输出及副作用：authoritative、candidate 只读；返回 status，不修改状态。
  // 失败/边界：plan 形状、ring/backing authority 变化，owned backing 未释放或缺完成证明均返回
  //   INVALID_ARGUMENT。
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

  // 功能：校验 candidate 的 queue 本地释放计划：各 backing、context、flush 目标均有释放证明。
  // 输入/输出及副作用：candidate 只读；返回 status，不修改状态。
  // 失败/边界：plan/backing/flush 缺失、ownership 非法、owned 未完成或缺证明、borrowed 已被释放、
  //   context 缺完成证明均返回 INVALID_ARGUMENT。
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

  // 设计：完成性是 adapter 定义的不透明事实；只在保留 authority 的 clone 上调用其虚查询，
  //   并拒绝 hook 边界上任何公开值、类型或 handle 别名的变更。
  // 功能：查询 owned mapping 的 release completion。
  // 输入/输出及副作用：mapping 输入；release_complete 输出（失败时为 0）；会克隆并调用 adapter hook。
  // 失败/边界：mapping 为空、guard/clone 非法、hook 返回 null 或改动了值/类型/别名返回
  //   INVALID_ARGUMENT；hook 自身失败 status 原样返回。
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
    status = rdma_resource_projector::project_mapping_value(
      mapping, "release completion input guard", saved_mapping
    );
    if (status == null || !status.ok() || mapping_type == null ||
        !rdma_resource_projector::mapping_hook_value_intact(mapping, saved_mapping, mapping_type))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "release completion input guard is invalid"
      );
    status = rdma_resource_projector::clone_owned_mapping_value(
      mapping, "release completion query", completion_query
    );
    if (status == null || !status.ok() || completion_query == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "release completion query clone is invalid"
      );
    query_type = completion_query.get_object_type();
    status = rdma_resource_projector::project_mapping_value(
      completion_query, "release completion query guard", saved_query
    );
    if (status == null || !status.ok() || query_type == null ||
        query_type != mapping_type ||
        !rdma_resource_projector::mapping_hook_value_intact(completion_query, saved_query,
                                   query_type) ||
        !rdma_resource_projector::mapping_handles_detached(mapping, completion_query))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "release completion query guard is invalid"
      );
    status = completion_query.release_completion_status(release_complete);
    if (status == null ||
        !rdma_resource_projector::mapping_hook_value_intact(mapping, saved_mapping, mapping_type) ||
        !rdma_resource_projector::mapping_hook_value_intact(completion_query, saved_query,
                                   query_type) ||
        !rdma_resource_projector::mapping_handles_detached(mapping, completion_query)) begin
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

  // 设计：recovery-only QP mapping 用于常规快照/等价 hook 不可用或已拒绝的场景；
  //   在受保护的具体 clone 上查询，使 adapter 的不透明封印保持权威而不重新开放这些 hook。
  // 功能：查询 recovery QP mapping 的 release completion。
  // 输入/输出及副作用：mapping 输入；release_complete 输出（失败时为 0）；克隆并调用 adapter hook。
  // 失败/边界：mapping 为空、clone/hook 返回 null 或失败、hook 改动值或别名时返回错误 status。
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
    status = rdma_resource_projector::clone_recovery_mapping_value(
      mapping, "QP recovery completion query", completion_query
    );
    if (status == null || !status.ok() || completion_query == null)
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP recovery completion query clone returned null"
      ) : status;
    status = rdma_status::nonnull(
      completion_query.release_completion_status(after_complete),
      "QP recovery completion query returned null"
    );
    if (!status.ok())
      return status;
    if (!rdma_resource_projector::same_mapping_value(mapping, completion_query) ||
        !rdma_resource_projector::mapping_handles_detached(mapping, completion_query))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "QP recovery completion query changed mapping value or aliases"
      );
    release_complete = after_complete;
    return rdma_status::success();
  endfunction

  // 功能：比较 QP backing ref 的字段、mapping 及 additional segment。
  // 输入/输出及副作用：lhs、rhs 只读，返回 bit。
  // 失败/边界：同为 null 返回 1，仅一侧为 null 或字段/段不一致返回 0。
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
      return rdma_resource_projector::same_mapping_value(lhs.mapping, rhs.mapping) &&
             same_owned_mapping_authority(lhs.mapping, rhs.mapping);
    return rdma_resource_projector::same_mapping_value(lhs.mapping, rhs.mapping);
  endfunction

  // 功能：比较 QP ring layout 的角色、entry 大小、深度、字节数和 object_mode。
  // 输入/输出及副作用：lhs、rhs 只读，返回 bit。
  // 失败/边界：同为 null 返回 1，仅一侧为 null 或字段不一致返回 0。
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

  // 功能：比较两份 context backing 快照：authority 值相等且 release_complete 相同。
  // 输入/输出及副作用：lhs、rhs 只读，返回 bit。
  // 失败/边界：同为空返回 1；单侧为空、authority/HMC 不一致或 release_complete 不同返回 0。
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

  // 功能：比较 QP backing plan 的传输、深度、flush/cleanup 标志、ring、各 backing ref 和 context。
  // 输入/输出及副作用：lhs、rhs 只读，返回 bit。
  // 失败/边界：同为 null 返回 1，仅一侧为 null 或任一字段/URC ref 不一致返回 0。
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
        !same_qp_backing_ref_value(lhs.rq_sgb_ref, rhs.rq_sgb_ref) ||
        !same_qp_backing_ref_value(lhs.rq_ref, rhs.rq_ref) ||
        !same_qp_backing_ref_value(lhs.sq_pd_ref, rhs.sq_pd_ref) ||
        !same_qp_backing_ref_value(lhs.rq_pd_ref, rhs.rq_pd_ref) ||
        !rdma_resource_projector::same_handle_instance(lhs.rq_source_h, rhs.rq_source_h) ||
        lhs.urc_refs.size() != rhs.urc_refs.size() ||
        !same_context_value(lhs.context_ref, rhs.context_ref))
      return 1'b0;
    foreach (lhs.urc_refs[i])
      if (!same_qp_backing_ref_value(lhs.urc_refs[i], rhs.urc_refs[i]))
        return 1'b0;
    return 1'b1;
  endfunction

  // 功能：比较 address vector 的全部字段和 destination_ip。
  // 输入/输出及副作用：lhs、rhs 只读，返回 bit。
  // 失败/边界：同为 null 返回 1，仅一侧为 null 或任一字段不一致返回 0。
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

  // 功能：比较 QPC behavior 字段（版本、迁移、字节序、fence、priority）。
  // 输入/输出及副作用：lhs、rhs 只读，返回 bit。
  // 失败/边界：同为 null 返回 1，仅一侧为 null 或字段不一致返回 0。
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

  // 功能：按 RC/UD/URC 子类比较 QPC transport 扩展字段。
  // 输入/输出及副作用：lhs、rhs 只读，返回 bit。
  // 失败/边界：同为 null 返回 1；两侧子类不匹配或不是 RC/UD/URC、URC 的 queues 为空时返回 0。
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

  // 功能：比较 QPC model 的句柄、传输、状态、深度、backing、地址向量、behavior 和扩展。
  // 输入/输出及副作用：lhs、rhs 只读，返回 bit。
  // 失败/边界：同为 null 返回 1，仅一侧为 null 或任一字段不一致返回 0。
  protected function bit same_qpc_value(
    rdma_qpc_model lhs,
    rdma_qpc_model rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return rdma_resource_projector::same_handle_instance(lhs.qp_h, rhs.qp_h) &&
           rdma_resource_projector::same_handle_instance(lhs.pd_h, rhs.pd_h) &&
           rdma_resource_projector::same_handle_instance(lhs.send_cq_h, rhs.send_cq_h) &&
           rdma_resource_projector::same_handle_instance(lhs.recv_cq_h, rhs.recv_cq_h) &&
           rdma_resource_projector::same_handle_instance(lhs.srq_h, rhs.srq_h) &&
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

  // 功能：比较两个 rdma_qp 的对账字段：句柄、状态、依赖拓扑、ring 指针、plan 和已编程 QPC。
  // 输入/输出及副作用：lhs、rhs 只读，返回 bit。
  // 失败/边界：同为 null 返回 1，仅一侧为 null 或任一字段不一致返回 0。
  protected function bit same_qp_reconciliation_value(
    rdma_qp lhs,
    rdma_qp rhs
  );
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return rdma_resource_projector::same_handle_instance(lhs.handle, rhs.handle) &&
           rdma_resource_projector::same_handle_instance(lhs.owner, rhs.owner) &&
           lhs.state == rhs.state &&
           lhs.backing_refs.size() == rhs.backing_refs.size() &&
           lhs.hmc_refs.size() == rhs.hmc_refs.size() &&
           rdma_resource_projector::same_dependency_topology(lhs, rhs) &&
           rdma_resource_projector::same_outstanding_ids(lhs, rhs) &&
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
           rdma_resource_projector::same_handle_instance(lhs.pd_h, rhs.pd_h) &&
           rdma_resource_projector::same_handle_instance(lhs.send_cq_h, rhs.send_cq_h) &&
           rdma_resource_projector::same_handle_instance(lhs.recv_cq_h, rhs.recv_cq_h) &&
           rdma_resource_projector::same_handle_instance(lhs.srq_h, rhs.srq_h) &&
           same_qp_plan_value(lhs.qp_plan, rhs.qp_plan) &&
           same_qpc_value(lhs.programmed_qpc, rhs.programmed_qpc);
  endfunction

  // 功能：为 registry 每项建立 detached schema 投影，再在单一 guard 窗口内一次性写回。
  // 输入/输出及副作用：operation 为诊断前缀；成功时替换 registry 条目，返回 status。
  // 失败/边界：投影失败/为 null、guard 忙、epoch 变化或条目被替换时返回错误且不写入任何投影；
  //   guard 只包围最终写回，外部投影阶段不持锁，避免反向重入死锁。
  protected function rdma_status registry_schema_status(string operation);
    rdma_resource projected_registry[string];
    rdma_resource source_registry[string];
    rdma_resource projected;
    rdma_status status;
    longint unsigned epoch_snapshot;

    epoch_snapshot = publication_epoch;
    foreach (registry[key]) begin
      source_registry[key] = registry[key];
      status = rdma_resource_projector::project_resource_value(
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

  // 功能：为 recovery_records 每项建立 detached 投影，再全量受保护提交，避免中途失败留下部分记录。
  // 输入/输出及副作用：operation 为诊断前缀；成功时只更新 recovery_records，返回 status。
  // 失败/边界：投影失败/为 null、guard 忙、epoch 变化或记录被替换时返回错误并保持原值。
  protected function rdma_status recovery_schema_status(string operation);
    rdma_recovery_record projected_records[string];
    rdma_recovery_record source_records[string];
    rdma_recovery_record projected;
    rdma_status status;
    longint unsigned epoch_snapshot;

    epoch_snapshot = publication_epoch;
    foreach (recovery_records[key]) begin
      source_records[key] = recovery_records[key];
      status = rdma_resource_projector::project_recovery_value(
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

  // 功能：为指定 key 建立单条 detached recovery 投影，并在 source 未变时原子替换。
  // 输入/输出及副作用：key、operation 输入；成功时只更新 recovery_records[key]。
  // 失败/边界：key 不存在时幂等成功；记录为空、投影失败、epoch/引用变化或 guard 忙返回错误。
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
    status = rdma_resource_projector::project_recovery_value(
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

  // 功能：把已完成外部 projection/identity/业务校验的 replacement 在一次 guard 窗口内装入 registry，
  //   并更新 staged_allocations 与 publication_epoch。
  // 输入/输出及副作用：expected_epoch/source 须取自外部校验前；validate 在锁外执行，锁内只写
  //   manager 自有 registry/staged/epoch；mark_staged/clear_staged 选择 staged 标志的变化。
  // 失败/边界：replacement/key 缺失、handle 身份与当前 registry 不一致、validate 失败、epoch 过期、
  //   source 改变或 guard 忙返回错误并保持原条目；mark 与 clear 同时置位属调用方契约错误。
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
    status = rdma_status::nonnull(
      replacement.validate(),
      {operation, " registry replacement validation returned null"}
    );
    if (!status.ok())
      return status;
    if (!registry.exists(key) || registry[key] == null ||
        registry[key].handle == null ||
        !rdma_resource_projector::same_handle_instance(registry[key].handle, replacement.handle))
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

  // 功能：判断 recovery 记录是否已无待办且可回收（硬件不存在，QP 创建回滚的 plan 已清理）。
  // 输入/输出及副作用：recovery 只读，返回 bit。
  // 失败/边界：为空、硬件非 ABSENT、仍有 pending 步骤；或 QP 创建回滚的 plan 缺失/未清理、
  //   仍有 staging/query mapping 或歧义票据时返回 0。
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
  // 功能：由 binding 构造其 Function handle。
  // 输入/输出及副作用：binding、handle_name 输入；返回新 handle，不修改 binding。
  // 失败/边界：不检查 binding 为空，调用方须保证非空。
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

  // 功能：在 generation_sources 中按引用反查 binding 登记键。
  // 输入/输出及副作用：binding 输入；key 输出（未找到时为空串）；返回是否找到。
  // 失败/边界：无。
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

  // 功能：从已登记 source 观察代际，单调推进 high-water 并记录 32 位回绕耗尽。
  // 输入/输出及副作用：key 定位 generation_sources；可能更新 generation_high_water 或置 generation_exhausted。
  // 失败/边界：source 不存在或为空时无操作；回退值不降低 high-water；
  //   已达最大值后再见 0 永久标记 exhausted，不能因后续失败撤销。
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

  // 功能：投影并校验 binding，得到可信 binding、Function owner 和 registry 键，判断是否需首次登记。
  // 输入/输出及副作用：输出 trusted_binding/owner/key/registration_needed；会先做 registry schema 投影，
  //   可能刷新 generation_high_water 或置 exhausted，其余只读。
  // 失败/边界：binding 为空、来源非已登记 binding、validate 失败或非 ACTIVE 返回错误；
  //   generation 缺账本、耗尽、回退、回绕或已 retired 分别返回 INVALID_STATE/RESOURCE_EXHAUSTED/STALE_GENERATION。
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
    status = rdma_resource_projector::project_binding_value(binding, "binding input",
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
      status = rdma_status::nonnull(
        projected_binding.validate(),
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
      status = rdma_resource_projector::project_binding_value(binding_snapshots[key],
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
    status = rdma_status::nonnull(
      trusted_binding.validate(),
      "Trusted Function binding validation returned null"
    );
    if (!status.ok())
      return status;
    if (trusted_binding.state != RDMA_BIND_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "function binding is not ACTIVE");
    return rdma_status::success();
  endfunction

  // 功能：原子完成首次 binding 登记和一次 local-ID/serial 消费，使资源与 Function 共用同一提交边界。
  // 输入/输出及副作用：source/trusted_binding/owner/kind 为已准入快照，expected_epoch 冻结于 admission 前；
  //   输出 local_id、used_free_id、registered_binding、prior_serial、reservation_epoch 供发布/补偿；
  //   成功恰好推进一次 epoch。
  // 失败/边界：投影失败、guard 忙、epoch 旧或饱和、登记来源变化、generation/retirement 漂移均不消费 ID；
  //   锁内不经过 factory 或外部 adapter。
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
      status = rdma_resource_projector::project_binding_value(trusted_binding, "binding registry", binding_copy);
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

    // admission 与此处之间 epoch 必须不变；以下仅操作 manager 自有字段，
    // 不得加入 status factory、clone 或 adapter 回调。binding 与 ID 同时生效。
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

  // 功能：校验 binding 为 ACTIVE 且代际合法，输出 owner。
  // 输入/输出及副作用：binding 输入；owner 输出；委托 binding_context_status。
  // 失败/边界：同 binding_context_status。
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

  // 功能：校验 Function owner 已登记、未 retired/耗尽，且代际为当前值。
  // 输入/输出及副作用：owner 输入；会刷新 generation 观察，返回 status。
  // 失败/边界：非 Function handle 或未登记返回 INVALID_STATE；retired、耗尽或非当前代际返回 STALE_GENERATION。
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

  // 功能：判断 registry 中是否存在同一 Function 但 generation 不同的资源。
  // 输入/输出及副作用：owner 输入；只读，返回 bit。
  // 失败/边界：无。
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

  // 功能：为普通资源预留 local ID 与唯一 incarnation serial，尚不发布 registry。
  // 输入/输出及副作用：输出 owner/handle/local_id 及补偿依据 used_free_id/registered_binding/
  //   prior_serial/reservation_epoch；入口先冻结 admission epoch，成功更新 allocator/首次 binding。
  // 失败/边界：binding/schema 失败、FUNCTION 或非法 kind、serial/ID 耗尽、旧代际仍有资源、
  //   锁忙或 epoch 旧/饱和均拒绝且不消费 ID；成功预留须由 caller 发布或补偿一次。
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

    // 保持 serial、local ID、旧代际资源的既有错误优先级；这些只是准备阶段检查，
    // commit 须再确认入口 epoch，不能把外部窗口后的旧结果当作分配依据。
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

  // 功能：把一次 identity 预留封装为 detached candidate，供 create_* 暂存回滚证据。
  // 输入/输出及副作用：binding、kind 输入；candidate 输出；调用 reserve_identity 更新 allocator，不发布资源。
  // 失败/边界：reserve_identity 失败原样返回并置 candidate=null；candidate 不完整时回滚预留并返回 INVALID_STATE。
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
      // reserve_identity() 已推进 allocator；candidate 形状校验失败时也须在丢弃前撤销预留，
      // 避免泄漏 ID/serial。
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

  // 功能：撤销未发布的普通资源预留；无交错 mutation 时恢复账本，否则只归还自身 local ID。
  // 输入/输出及副作用：candidate 委托 rollback_identity_reservation 后被清空；不删除已发布 registry 条目。
  // 失败/边界：null 或已 clear 幂等；仅限未发布的预留，已发布资源须走 finalize/release。
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

  // 功能：为新资源候选填入 identity 的 handle/owner，并置为 ALLOCATED。
  // 输入/输出及副作用：只写 authoritative 的 handle/owner/state；identity 只读。
  // 失败/边界：调用方保证两者非空。
  protected function void init_candidate(
    rdma_resource_identity_candidate identity,
    rdma_resource authoritative
  );
    authoritative.handle = identity.handle;
    authoritative.owner = identity.owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
  endfunction

  // 功能：复制依赖句柄，一份作为类型化副本输出，一份追加到 authoritative.dependencies。
  // 输入/输出及副作用：typed_h 输出副本；成功时 dependencies 追加一项。
  // 失败/边界：投影失败时回滚 identity 预留并返回该状态。
  protected function rdma_status attach_dependency(
    rdma_resource_identity_candidate identity,
    rdma_resource authoritative,
    rdma_handle dependency_h,
    string label,
    output rdma_handle typed_h
  );
    rdma_status status;
    rdma_handle dependency_copy;

    status = rdma_resource_projector::project_handle_value(
      dependency_h, label, typed_h
    );
    if (status.ok())
      status = rdma_resource_projector::project_handle_value(
        dependency_h, {label, " dependency"}, dependency_copy
      );
    if (!status.ok()) begin
      rollback_identity_candidate(identity);
      return status;
    end
    authoritative.dependencies.push_back(dependency_copy);
    return status;
  endfunction

  // 功能：发布普通资源 candidate：校验形状与 epoch，经 register_resource 登记，失败则回滚预留。
  // 输入/输出及副作用：published 输出 detached 快照；成功清除 candidate，失败也回滚并清除。
  // 失败/边界：candidate/authoritative 不完整或 epoch 落后返回 INVALID_STATE（落后时仅返还自身 ID）；
  //   register_resource 返回 null/失败/无资源时归一化并回滚；Function 须走专用路径。
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

  // 功能：发布 Function candidate：校验 freshness 与完整性，经 register_resource 登记。
  // 输入/输出及副作用：published 输出；成功清除 candidate，失败回滚 Function ID 预留；
  //   仅同 epoch 的独占失败才撤销首次 binding。
  // 失败/边界：candidate/authoritative 不完整、epoch 落后或 register_resource 失败均返回错误，不留部分发布。
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

  // 功能：为 Function 创建预留 generation/tombstone/local-ID，封装为 detached candidate。
  // 输入/输出及副作用：candidate 输出 trusted binding、owner、handle、local ID 及首次登记标记；
  //   入口冻结 admission epoch，共同 commit 更新 binding/allocator 账本，不发布 Function。
  // 失败/边界：binding 为空、incarnation 已存在或已释放、旧 generation 仍存活、ID 耗尽、投影失败、
  //   锁忙或 epoch 旧/饱和时返回错误，且不遗留 ID、首次登记或半成品 candidate。
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
    if (status.ok())
      status = rdma_resource_projector::project_function_handle_value(
        candidate.owner, "Function identity handle", candidate.handle
      );
    if (status.ok())
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

  // 功能：撤销 Function 未发布预留；Function 不参与 serial 恢复。
  // 输入/输出及副作用：candidate 委托 rollback_identity_reservation 后被清空，不删除已发布 Function 或 tombstone。
  // 失败/边界：null/已 clear 幂等；epoch 过期时只返还 ID，不回退游标，也不移除他人共享的 binding。
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

  // 功能：返还 local ID；独占 fresh 分配恢复尾游标，有交错 mutation 则入 free-list，避免撞上后续 ID。
  // 输入/输出及副作用：used_free_id 表示来自空闲池，exclusive 表示预留后无其它 mutation；
  //   只改该 kind 的 free-list/next_local_id/exhausted 标志。
  // 失败/边界：caller 保证 ID 有效、未发布、只补偿一次；达上限时仅独占回滚清 exhausted，不做 32 位加一。
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

  // 功能：撤销独占失败预留首次登记且代际未变的 binding。
  // 输入/输出及副作用：先刷新 generation 观察值，仍等于 owner.generation 时删除四份 binding 记录。
  // 失败/边界：caller 须先证明无交错 mutation；非首次登记、已见新 generation 或已 exhausted 时保留记录。
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

  // 功能：统一补偿普通对象与 Function 的未发布预留，只撤销仍独占的账本变化。
  // 输入/输出及副作用：参数来自可信 candidate；恰好推进一次 publication_epoch，不调用 factory/adapter。
  // 失败/边界：每个有效预留只调用一次；epoch 不同或饱和时不恢复游标/serial/binding，仅返还 ID。
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

  // 功能：在写 registry/代际账本前完成资源发布所需的 detached 投影，收束到 candidate。
  // 输入/输出及副作用：resource、copy_label 输入；candidate 输出；可能调用外部 clone/factory，
  //   但只写 candidate，不改 registry、incarnation 或 allocator。
  // 失败/边界：resource/owner/handle 为空、投影失败/为 null、key 不一致或 candidate 无效返回错误，
  //   并清除 candidate，caller 不得提交半成品。
  protected function rdma_status stage_resource_publication(
    rdma_resource resource,
    string copy_label,
    output rdma_resource_publication_candidate candidate
  );
    rdma_status status;

    candidate = new("resource_publication_candidate");
    // projection 可能触发外部 clone/factory 或 completion 查询；先锁存 manager epoch，
    // 返回后再确认这些调用没有重入修改 registry/allocator。
    candidate.manager_epoch = publication_epoch;
    status = rdma_resource_projector::project_resource_value(
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
    status = rdma_resource_projector::project_resource_value(
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
    status = rdma_resource_projector::project_function_handle_value(
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
    status = rdma_resource_projector::project_handle_value(
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

  // 功能：把已 stage 的 candidate 一次性写入 registry、incarnation owner/handle 和 known generation。
  // 输入/输出及副作用：candidate 输入；成功时更新四份账本并推进 epoch；不调用 factory/clone，
  //   candidate 保留 detached 输出，由 caller 复制 published 后 clear。
  // 失败/边界：guard 为空或忙返回 RESOURCE_BUSY（不读写账本）；candidate 为空/无效、epoch 过期或
  //   registry/incarnation key 已存在返回 INVALID_STATE；重复 key 检查防止旧 candidate 覆盖后发布者。
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

  // 功能：兼容 create_* 与 Function 入口，分 detached stage 与无外部调用 commit 两段发布资源。
  // 输入/输出及副作用：resource、copy_label 输入；published 输出 detached 快照，失败时为 null。
  // 失败/边界：投影、candidate 校验或 commit 失败均原样/归一化返回，不重试，不发布半成品。
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

  // 功能：按 function_uid、kind、object_id 查找任一已知 incarnation，返回其 owner 快照。
  // 输入/输出及副作用：handle 输入；owner 输出（未找到为 null）；返回是否找到。
  // 失败/边界：忽略 owner/handle 记录缺失的条目。
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

  // 功能：校验依赖 handle 的类型、存在性、状态及同属 owner，供新资源准入使用。
  // 输入/输出及副作用：owner、dependency、expected_kind、allow_null 输入；只读，返回 status。
  // 失败/边界：为空且不允许、kind 不符或 owner 不同返回 INVALID_ARGUMENT；依赖处于 QUIESCING/ERROR
  //   返回 INVALID_STATE；lookup 失败原样返回。
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
        !rdma_resource_projector::same_handle_instance(dependency_resource.owner, owner))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource dependency has another owner");
    return rdma_status::success();
  endfunction

  // 功能：按 resource.handle.kind 转成具体资源类并返回其 local_*_id。
  // 输入/输出及副作用：resource 为输入；只读。
  // 失败/边界：cast 失败或 kind 无 local ID 池时 uvm_fatal。
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

  // 功能：判断 candidate.dependencies 中是否直接包含 dependency（按 handle 实例比较）。
  // 输入/输出及副作用：只读，返回 bit。
  // 失败/边界：任一参数为 null 返回 0。
  protected function bit resource_depends_on(
    rdma_resource candidate,
    rdma_handle dependency
  );
    if (candidate == null || dependency == null)
      return 1'b0;
    foreach (candidate.dependencies[i]) begin
      if (candidate.dependencies[i] != null &&
          rdma_resource_projector::same_handle_instance(candidate.dependencies[i], dependency))
        return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：判断 registry 中是否有其它资源依赖 resource（Function 还包含 owner 关系）。
  // 输入/输出及副作用：只读 registry，返回 bit。
  // 失败/边界：无。
  protected function bit has_dependents(rdma_resource resource);
    foreach (registry[key]) begin
      if (registry[key] == resource)
        continue;
      if (resource_depends_on(registry[key], resource.handle))
        return 1'b1;
      if (resource.handle.kind == RDMA_RESOURCE_FUNCTION &&
          registry[key].owner != null &&
          rdma_resource_projector::same_handle_instance(registry[key].owner, resource.handle))
        return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：扫描 registry，为 quiesce/finalize/release admission 生成 detached 的依赖与 outstanding 快照。
  //  含 QP/SRQ 分类字段，供 CQ resize 等策略复用同一次扫描。
  // 输入/输出及副作用：resource 输入，snapshot 输出；只读 registry 与 outstanding_ids，不改账本。
  // 失败/边界：resource 为 null 时 snapshot 全零；caller 须自行保持“依赖先于 outstanding”的错误优先级。
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
          rdma_resource_projector::same_handle_instance(registry[key].owner, resource.handle))
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

  // 设计：单资源 finalize 与 Function teardown 共用此提交窗口；先校验整批 ID 再删除，避免批内
  //  free-list 冲突导致部分资源已释放。caller 须在 admission/外部 completion 查询前冻结 epoch。
  // 功能：原子提交有序释放集合：清 recovery/staged、归还 local ID，可选标记 generation retired。
  // 输入/输出及副作用：keys 按依赖顺序；epoch_snapshot 为 admission 代际；operation 为诊断前缀。
  //  只改 manager 账本，保留 incarnation tombstone，不调用外部 adapter。
  // 失败/边界：guard 忙、epoch 过期、key/handle 缺失或不一致、kind 非法、ID 越界、批内重复或
  //  free-list 冲突均整批拒绝；空集合仅在需要 retire generation 时推进代际。cast 损坏按
  //  resource_local_id 报 fatal。
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

  // 功能：把单资源释放包装为释放集合，不重采 epoch，使外部查询期间的 mutation 仍被 OCC 拦截。
  // 输入/输出及副作用：key 为已校验资源，epoch_snapshot 来自 caller；成功则删除资源并回收 local ID。
  // 失败/边界：未知 key、epoch 过期、ID 重复/越界或 guard 忙时原样返回，不写账本。
  protected function rdma_status force_release_key(
    string key,
    longint unsigned epoch_snapshot
  );
    string keys[$];

    keys.push_back(key);
    return commit_resource_releases(keys, epoch_snapshot, "release resource");
  endfunction

  // 功能：通过 Function identity candidate 预留 owner/local ID/binding，发布 Function 资源。
  // 输入/输出及副作用：binding 输入；function_resource 输出发布后的快照；失败时 candidate 回滚预留。
  // 失败/边界：binding 空/过期/重复、旧 generation 仍存活、tombstone 已存在、ID 耗尽、投影或
  //  register 失败均回滚返回；发布类型不符 uvm_fatal。
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
    status = rdma_resource_projector::project_function_handle_value(identity.owner, "Function owner",
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
    status = rdma_resource_projector::project_binding_value(identity.trusted_binding, "Function resource",
                                   authoritative.binding);
    if (status.ok())
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

  // 功能：预留并发布 PD。
  // 输入/输出及副作用：binding 输入；pd 输出 detached 快照；成功更新 allocator/registry。
  // 失败/边界：预留或发布失败返回错误且 pd=null；发布类型不符 uvm_fatal。
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
    init_candidate(identity, authoritative);
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
    rdma_function_handle owner;
    rdma_resource_identity_candidate identity;
    rdma_mr authoritative;
    rdma_resource published;

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
    init_candidate(identity, authoritative);
    authoritative.local_mr_id = identity.local_id;
    authoritative.global_mr_id = identity.handle.object_id;
    // reservation 已有 local index 但尚无 hardware key：保留 index、低 8 位置零，使未 stage 的 MR
    //  也能发布本地 ERROR cleanup。该值不是可用 MPT key，stage 仍须提供正式 key。
    authoritative.lkey = {identity.local_id[23:0], 8'h00};
    status = attach_dependency(identity, authoritative, pd_h, "MR PD",
                               authoritative.pd_h);
    if (!status.ok())
      return status;
    status = publish_identity_candidate(identity, authoritative,
                                        "create MR", published);
    if (!status.ok())
      return status;
    if (!$cast(mr, published))
      `uvm_fatal("RM_COPY_TYPE", "published MR type mismatch")
    return rdma_status::success();
  endfunction

  // 功能：预留并发布 CQ，可选登记对 CEQ 的依赖。
  // 输入/输出及副作用：binding、ceq_h 输入（ceq_h 可为 null）；cq 输出；成功更新 allocator/registry。
  // 失败/边界：binding 无效、CEQ 无效或 closing、预留/发布失败返回错误且 cq=null；类型不符 uvm_fatal。
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
    init_candidate(identity, authoritative);
    authoritative.local_cq_id = identity.local_id;
    authoritative.global_cq_id = identity.handle.object_id;
    if (ceq_h != null) begin
      status = attach_dependency(identity, authoritative, ceq_h, "CQ CEQ",
                                 authoritative.ceq_h);
      if (!status.ok())
        return status;
    end
    status = publish_identity_candidate(identity, authoritative,
                                        "create CQ", published);
    if (!status.ok())
      return status;
    if (!$cast(cq, published))
      `uvm_fatal("RM_COPY_TYPE", "published CQ type mismatch")
    return rdma_status::success();
  endfunction

  // 功能：预留并发布 QP，登记 PD/send CQ/recv CQ/可选 SRQ 依赖，并推进 QP incarnation sequence。
  // 输入/输出及副作用：binding 及各依赖 handle 输入（srq_h 可为 null）；qp 输出；成功更新 qp_sequences。
  // 失败/边界：binding 或任一依赖无效/closing、预留/发布失败返回错误且 qp=null；类型不符 uvm_fatal。
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
    init_candidate(identity, authoritative);
    authoritative.local_qp_id = identity.local_id;
    authoritative.global_qp_id = identity.handle.object_id;
    status = attach_dependency(identity, authoritative, pd_h, "QP PD",
                               authoritative.pd_h);
    if (status.ok())
      status = attach_dependency(identity, authoritative, send_cq_h,
                                 "QP send CQ", authoritative.send_cq_h);
    if (status.ok())
      status = attach_dependency(identity, authoritative, recv_cq_h,
                                 "QP receive CQ", authoritative.recv_cq_h);
    if (status.ok() && srq_h != null)
      status = attach_dependency(identity, authoritative, srq_h, "QP SRQ",
                                 authoritative.srq_h);
    if (!status.ok())
      return status;
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

  // 功能：查询某 Function 下 local QPN 的 incarnation sequence。
  // 输入/输出及副作用：owner、local_qpn 输入；sequence_value 输出；只读。
  // 失败/边界：owner 投影失败、QPN 越界、binding 无效或 sequence 未登记返回错误，值为 0。
  virtual function rdma_status qp_sequence(
    rdma_function_handle owner,
    int unsigned local_qpn,
    output bit [7:0] sequence_value
  );
    rdma_function_handle trusted_owner;
    rdma_status status;
    string key;

    sequence_value = '0;
    status = rdma_resource_projector::project_function_handle_value(owner, "QP sequence owner",
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

  // 功能：预留并发布 SRQ，登记 PD 依赖。
  // 输入/输出及副作用：binding、pd_h 输入；srq 输出；成功更新 allocator/registry。
  // 失败/边界：binding/PD 无效、预留或发布失败返回错误且 srq=null；类型不符 uvm_fatal。
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
    init_candidate(identity, authoritative);
    authoritative.local_srq_id = identity.local_id;
    authoritative.global_srq_id = identity.handle.object_id;
    status = attach_dependency(identity, authoritative, pd_h, "SRQ PD",
                               authoritative.pd_h);
    if (!status.ok())
      return status;
    status = publish_identity_candidate(identity, authoritative,
                                        "create SRQ", published);
    if (!status.ok())
      return status;
    if (!$cast(srq, published))
      `uvm_fatal("RM_COPY_TYPE", "published SRQ type mismatch")
    return rdma_status::success();
  endfunction

  // 功能：预留并发布 CMQ。
  // 输入/输出及副作用：binding 输入；cmq 输出；成功更新 allocator/registry。
  // 失败/边界：预留或发布失败返回错误且 cmq=null；类型不符 uvm_fatal。
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
    init_candidate(identity, authoritative);
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

  // 功能：预留并发布 CEQ。
  // 输入/输出及副作用：binding 输入；ceq 输出；成功更新 allocator/registry。
  // 失败/边界：预留或发布失败返回错误且 ceq=null；类型不符 uvm_fatal。
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
    init_candidate(identity, authoritative);
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

  // 功能：预留并发布 AEQ。
  // 输入/输出及副作用：binding 输入；aeq 输出；成功更新 allocator/registry。
  // 失败/边界：预留或发布失败返回错误且 aeq=null；类型不符 uvm_fatal。
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
    init_candidate(identity, authoritative);
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

  // 功能：按完整 incarnation 查 registry，校验 owner binding 后返回 detached 资源。
  // 输入/输出及副作用：handle 为查找键；resource 输出双层投影快照；可刷新 generation high-water，
  //  不把查询投影写回 registry，避免重入查询覆盖已提交状态。
  // 失败/边界：handle 空/畸形/未知/已释放、binding 过期、投影失败或投影期间 epoch/source 变化返回错误，
  //  resource=null；旧 generation 优先于 released 诊断。
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
    status = rdma_resource_projector::project_handle_value(handle, "lookup", trusted_handle);
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
      status = rdma_resource_projector::project_resource_value(source_resource, "lookup registry entry",
                                      authoritative);
      if (!status.ok())
        return status;
      if (authoritative.handle == null ||
          !rdma_resource_projector::same_handle_instance(authoritative.handle, trusted_handle))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "registry identity is inconsistent");
      status = owner_binding_status(authoritative.owner);
      if (!status.ok())
        return status;
      status = rdma_resource_projector::project_resource_value(authoritative, "lookup", detached);
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

  // 设计说明：registry 遍历只做只读匹配；project_resource_value 会触发 factory/快照复制，不能在
  //  “多个 live 命中”的歧义分支里提前执行，故匹配与 detached 投影分开，caller 确认唯一后才发布。
  // 功能：按 owner、kind、local_id 扫描 registry，收集唯一 live 候选及 stale/released/multiple 证据。
  // 输入/输出及副作用：入参已由 caller 校验；输出 live_candidate 与各 found_*/multiple_live 标志；只读。
  // 失败/边界：旧 generation 只置 found_stale；RELEASED 仅同 local_id 置 found_released；NEW/ERROR 跳过；
  //  第二个 live 命中置 multiple_live 并停止，caller 须在投影前返回歧义错误。
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

  // 功能：按当前 Function owner、kind、完整 local_id 反查唯一权威资源，供 AEQE/CEQE 等 wire owner 路由。
  // 输入/输出及副作用：resource 输出 detached 快照；只读 binding/registry，不截断 wire ID。
  // 失败/边界：owner 空/非当前 generation、kind 不支持、local_id 超宽、无匹配、已 RELEASED、多个 live
  //  或仅有旧 generation 记录时返回明确错误；不同 UID/Function/generation 的资源不会命中。
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

    status = rdma_resource_projector::project_function_handle_value(
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
      status = rdma_resource_projector::project_resource_value(
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

  // 功能：校验普通资源可编程后，把 detached 候选保留为 ALLOCATED 并标记 staged。
  // 输入/输出及副作用：成功原子替换 registry/暂存标志并推进 epoch；不分配 ID；PD 不做 PROGRAMMED 预检。
  // 失败/边界：QP、非 ALLOCATED、identity/投影/validate 失败、epoch/source 变化或锁忙均拒绝并保持原状。
  virtual function rdma_status stage_allocated(rdma_resource candidate);
    rdma_resource authoritative;
    rdma_resource prepared;
    rdma_resource replacement;
    rdma_status status;
    rdma_resource source_resource;
    longint unsigned epoch_snapshot;
    string key;

    epoch_snapshot = publication_epoch;
    status = rdma_resource_projector::project_public_resource_value(candidate, "stage allocated",
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
    status = rdma_resource_projector::publication_identity_status(replacement, authoritative);
    if (!status.ok())
      return status;
    if (replacement.handle.kind != RDMA_RESOURCE_PD) begin
      status = rdma_resource_projector::project_public_resource_value(replacement, "stage prepared",
                                           prepared);
      if (!status.ok())
        return status;
      prepared.state = RDMA_RESOURCE_PROGRAMMED;
      status = rdma_status::nonnull(
        prepared.validate(),
        "prepared staged candidate validation returned null"
      );
      if (!status.ok())
        return status;
    end
    replacement.state = RDMA_RESOURCE_ALLOCATED;
    status = rdma_status::nonnull(
      replacement.validate(),
      "staged candidate validation returned null"
    );
    if (!status.ok())
      return status;
    return commit_registry_replacement(
      key, replacement, "stage allocated", epoch_snapshot, source_resource, 1'b1
    );
  endfunction

  // 功能：把已校验的 CQC context 绑定到 ALLOCATED 且 staged 的 CQ，使各路径共享 typed snapshot。
  // 输入/输出及副作用：candidate 须带 CQ handle、queue plan 和 programmed_cqc；成功替换 registry 快照，
  //  保留 staged 标记。
  // 失败/边界：candidate 空/类型或状态错、缺 CQC、CQC 身份不符、validate 失败、registry 非 staged
  //  ALLOCATED、已有 CQC、identity/epoch/source 变化或锁忙均报错，不改 registry。
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

    status = rdma_resource_projector::project_public_resource_value(
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

    status = rdma_resource_projector::publication_identity_status(replacement, authoritative);
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

  // 功能：把已 staged 的普通资源从 ALLOCATED 发布为 PROGRAMMED。
  // 输入/输出及副作用：candidate 为 detached 编程结果；成功更新 registry、清 staged、推进 epoch；不执行硬件命令。
  // 失败/边界：QP/PD、候选或 authority 非 ALLOCATED、未 staged、identity/validate 失败、epoch/source 冲突或
  //  锁忙时拒绝，保留原资源与暂存证据。
  virtual function rdma_status commit_programmed(rdma_resource candidate);
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_status status;
    rdma_resource source_resource;
    longint unsigned epoch_snapshot;
    string key;

    epoch_snapshot = publication_epoch;
    status = rdma_resource_projector::project_public_resource_value(candidate, "commit programmed",
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
    status = rdma_resource_projector::publication_identity_status(replacement, authoritative);
    if (!status.ok())
      return status;
    replacement.state = RDMA_RESOURCE_PROGRAMMED;
    status = rdma_status::nonnull(
      replacement.validate(),
      "programmed candidate validation returned null"
    );
    if (!status.ok())
      return status;
    return commit_registry_replacement(
      key, replacement, "commit programmed", epoch_snapshot, source_resource,
      1'b0, 1'b1
    );
  endfunction

  // 功能：把 PD 的 ALLOCATED 或其它资源的 PROGRAMMED 快照发布为 ACTIVE。
  // 输入/输出及副作用：handle 定位 authority；成功替换 detached resource、清 staged、推进 epoch。
  // 失败/边界：lookup 失败、来源状态不符（含重复激活）、投影/validate 失败、epoch/source 变化或锁忙时
  //  不激活，保留 staged。
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
    status = rdma_resource_projector::project_resource_value(registry[key], "activate", replacement);
    if (!status.ok())
      return status;
    replacement.state = RDMA_RESOURCE_ACTIVE;
    status = rdma_status::nonnull(
      replacement.validate(),
      "active resource validation returned null"
    );
    if (!status.ok())
      return status;
    return commit_registry_replacement(
      key, replacement, "activate", epoch_snapshot, source_resource, 1'b0, 1'b1
    );
  endfunction

  // 功能：校验代际并读取 blocker snapshot 后，把 ACTIVE 资源切到 QUIESCING，阻止新提交。
  // 输入/输出及副作用：handle 输入；成功经 commit_registry_replacement 更新 state。
  // 失败/边界：非 ACTIVE 返回 INVALID_STATE；有 live dependent 或 outstanding 返回 RESOURCE_BUSY（依赖优先）；
  //  schema/投影失败、epoch/source 冲突或锁忙同样拒绝。
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
    status = rdma_resource_projector::project_resource_value(registry[key], "begin quiesce",
                                    replacement);
    if (!status.ok())
      return status;
    replacement.state = RDMA_RESOURCE_QUIESCING;
    return commit_registry_replacement(
      key, replacement, "begin quiesce", epoch_snapshot, source_resource
    );
  endfunction

  // 功能：为 CQ backing replacement 建立专用 quiesce 屏障，允许仍被空闲 QP 引用的 CQ 进入 QUIESCING。
  // 输入/输出及副作用：handle 输入；读取依赖与 outstanding_ids，原子更新 CQ state；保留完整依赖拓扑。
  // 失败/边界：非 CQ、非 ACTIVE、CQ 有 outstanding、依赖资源仍有活动事务、schema/投影/validate 失败、
  //  epoch/source 变化或锁忙时不写 registry，CQ 保持 ACTIVE。
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
    // CQ 换 ring 期间可仍被空闲 QP 引用；用 detached snapshot 区分该允许情形与非 QP dependent 或带
    //  活动的 QP，避免在策略专用循环里二次读取可变 registry。
    snapshot_activity_blockers(registry[key], blockers);
    if (rdma_resource_dependency_policy::blocks_release(
          blockers, RDMA_RESOURCE_RELEASE_CQ_RESIZE))
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "CQ has an active dependent resource");
    status = rdma_resource_projector::project_resource_value(registry[key], "begin CQ resize",
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

  // 功能：对 QUIESCING 的 CQ 原子发布新的 ACTIVE geometry/backing，并校验身份、依赖、queue plan 不变。
  // 输入/输出及副作用：candidate 输入；全部检查通过后单次替换 registry CQ；不直接释放旧 backing。
  // 失败/边界：candidate 空/类型或状态错、registry 非 QUIESCING、ring/ref geometry 不符、plan/身份/依赖
  //  改变、validate 失败、epoch/source 冲突或锁忙时拒绝，registry 保持原值。
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
    status = rdma_resource_projector::publication_identity_status(candidate, authoritative);
    if (!status.ok()) return status;
    status = rdma_resource_projector::project_public_resource_value(candidate, "replace active CQ",
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
    // 下方 helper 是唯一发布点，上面的 detached 投影与 geometry 检查须先全部完成。
    return commit_registry_replacement(
      key, replacement_cq, "replace active CQ", epoch_snapshot, source_resource
    );
  endfunction

  // 功能：把带 qp_plan/QPC 的 ALLOCATED 候选附着到干净 QP reservation 并发布 PROGRAMMED，
  //  保留旧代际 exact-incarnation 的恢复登记入口。
  // 输入/输出及副作用：candidate 为 detached 编程证据；成功替换 registry、推进 epoch；epoch 在首次
  //  投影前冻结，source 在 authority 投影前冻结；不执行硬件提交。
  // 失败/边界：候选不完整、目标非干净 reservation、identity/validate 失败或 OCC/锁冲突时拒绝。
  //  仅当同一旧 incarnation 仍在 registry 时 STALE_GENERATION 才走 fallback，未知旧句柄保留原错误。
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
    status = rdma_resource_projector::project_public_resource_value(candidate, "attach QP programming",
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
          rdma_resource_projector::same_handle_instance(registry[key].handle, replacement.handle)) begin
        // 旧代际 lookup 不返回资源；须在 fallback 外部 projection 前冻结引用，不能投影后重取。
        source_resource = registry[key];
        status = rdma_resource_projector::project_resource_value(
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
    status = rdma_resource_projector::publication_identity_status(replacement, authoritative);
    if (!status.ok())
      return status;
    replacement.state = RDMA_RESOURCE_PROGRAMMED;
    status = rdma_status::nonnull(
      replacement.validate(),
      "QP programming validation returned null"
    );
    if (!status.ok())
      return status;
    return commit_registry_replacement(
      key, replacement, "attach QP programming", epoch_snapshot, source_resource
    );
  endfunction

  // 功能：提交 ACTIVE QP 的 RESET→INIT 语义迁移，保留硬件 QPC image。
  // 输入/输出及副作用：qp_h 定位 QP，state 须为 INIT；成功只更新 detached qp_state 并推进 epoch。
  // 失败/边界：非 QP、非 ACTIVE RESET、请求非 INIT、投影/validate 失败、epoch/source 变化或锁忙时保持旧值。
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
    status = rdma_resource_projector::project_resource_value(registry[key], "commit QP semantic state",
                                    projected);
    if (!status.ok() || !$cast(replacement, projected))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP semantic-state projection failed"
      ) : status;
    replacement.qp_state = state;
    status = rdma_status::nonnull(
      replacement.validate(),
      "QP semantic-state validation returned null"
    );
    if (!status.ok())
      return status;
    return commit_registry_replacement(
      key, replacement, "commit QP semantic state", epoch_snapshot, source_resource
    );
  endfunction

  // 功能：校验普通或 ERROR reconciliation 的 QP programmed image，经双账本 OCC 发布 ACTIVE replacement，
  //  reconciliation 成功时同步清除已消费的 recovery record。
  // 输入/输出及副作用：candidate 输入；只更新 manager registry/recovery，成功后推进 publication_epoch。
  // 失败/边界：authority、QPC/recovery 歧义、release completion、validate、epoch/source 或 guard 任一失败
  //  则保持原状态，不半清 recovery。
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

    status = rdma_resource_projector::project_public_resource_value(candidate, "commit QP programmed",
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
    status = rdma_resource_projector::publication_identity_status(replacement, authoritative);
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
      status = rdma_resource_projector::project_qpc_value(
        replacement.programmed_qpc, "commit QP requested QPC",
        requested_qpc
      );
      if (!status.ok() || requested_qpc == null)
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "requested QP programmed QPC projection failed"
        ) : status;
      status = rdma_resource_projector::project_resource_value(
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
      status = rdma_resource_projector::project_resource_value(
        registry[key], "commit QP expected reconciliation", projected
      );
      if (!status.ok() || !$cast(expected_replacement, projected))
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "expected QP reconciliation projection failed"
        ) : status;
      status = rdma_resource_projector::project_qpc_value(
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
      // ERROR 快照不携带语义生命周期状态。RESET→INIT→RTR 歧义后选 prior image 时，programmed image 仍是
      //  RESET 而软件已到 INIT，故显式恢复该状态而不是发布 ERROR。
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
    status = rdma_status::nonnull(replacement.validate(), "programmed QP validation returned null");
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

  // 功能：把 QP 切到 ERROR 并登记（或替换）recovery record，保留可回滚的故障证据。
  // 输入/输出及副作用：qp_h、recovery 为输入；经双账本 OCC 同时发布 ERROR 资源与 recovery record。
  // 失败/边界：代际/资源不匹配、recovery 与已登记 plan/QPC/mapping/opcode 不一致、进度回退、状态不允许、
  //  epoch/source 冲突或锁忙时拒绝并保留原账本；仅同一旧 incarnation 的合法 recovery 可越过 stale 门禁。
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
          rdma_resource_projector::same_handle_instance(registry[key].handle, qp_h) &&
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
          status = rdma_resource_projector::project_qp_recovery_value(
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
            rdma_resource_projector::same_handle_instance(recovery_qp_h, registry[key].handle) &&
            registry[key].owner != null &&
            rdma_resource_projector::same_handle_instance(recovery_owner, registry[key].owner);
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
          status = rdma_resource_projector::project_resource_value(
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
      status = rdma_resource_projector::project_qp_recovery_value(
        recovery, "mark pre-program QP ERROR", recovery_copy
      );
      if (!status.ok() || recovery_copy == null)
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "pre-program QP recovery projection is empty"
        ) : status;
      status = rdma_status::nonnull(
        recovery_copy.validate(),
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
      status = rdma_resource_projector::project_qp_recovery_value(recovery, "mark QP ERROR",
                                         recovery_copy);
      if (!status.ok() || recovery_copy == null)
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT, "QP recovery projection is empty"
        ) : status;
      status = rdma_status::nonnull(
        recovery_copy.validate(),
        "QP recovery validation returned null"
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
          !rdma_resource_projector::same_handle_instance(recovery_qp_h, authoritative_qp.handle) ||
          recovery_owner == null || authoritative_qp.owner == null ||
          !rdma_resource_projector::same_handle_instance(recovery_owner, authoritative_qp.owner) ||
          (authoritative_qp.srq_h == null) !=
            (recovery_copy.qp_plan.rq_source_h == null) ||
          (authoritative_qp.srq_h != null &&
           !rdma_resource_projector::same_handle_instance(authoritative_qp.srq_h,
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
      // 重试时 adapter 可能再次不返回 ticket（如 destroy ERROR MODIFY），需持久化刷新已有的无 ticket
      //  歧义标记：保留 operation/role authority，进度与保留的 authority 都不得变化。
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
          !rdma_resource_projector::same_mapping_value(recovery_copy.staging_mapping,
                              existing_recovery.staging_mapping) ||
          recovery_copy.staging_mapping != null &&
            !same_owned_mapping_authority(
              recovery_copy.staging_mapping,
              existing_recovery.staging_mapping
            ) ||
          !rdma_resource_projector::same_mapping_value(recovery_copy.query_mapping,
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
    status = rdma_resource_projector::project_resource_value(registry[key], "mark QP ERROR resource",
                                    projected);
    if (!status.ok() || !$cast(replacement, projected))
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP ERROR resource projection failed"
      ) : status;
    replacement.state = RDMA_RESOURCE_ERROR;
    if (preprogram_publication) begin
      status = rdma_resource_projector::project_qp_plan_value(
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
    status = rdma_status::nonnull(
      replacement.validate(),
      "QP ERROR resource validation returned null"
    );
    if (!status.ok())
      return status;

    if (error_replacement) begin
      status = rdma_resource_projector::project_recovery_value(
        recovery_records[key], "replace QP ERROR record", record_copy
      );
      if (!status.ok())
        return status;
      record_copy.qp_recovery = recovery_copy;
      // 嵌套 QP recovery 状态在 CREATE/DELETE 歧义被 QPC_QUERY 或终态 CMQ 结果消解后是权威来源；校验前
      //  须同步 record 级 presence，否则 UNKNOWN 顶层值加已清空的 ticket 会被判为非法 schema。
      if (recovery_copy.query_presence_known)
        record_copy.hardware_presence = recovery_copy.query_presence;
    end
    else begin
      record_copy = new("qp_recovery_record");
      status = rdma_resource_projector::project_handle_value(authoritative.handle, "QP recovery handle",
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
    status = rdma_status::nonnull(
      record_copy.validate(),
      "QP recovery record validation returned null"
    );
    if (!status.ok())
      return status;

    // 持久 recovery authority 与 ERROR 资源一并发布。
    return commit_resource_recovery_replacement(
      key, replacement, record_copy, 1'b1, 1'b0, 1'b1,
      source_resource, source_recovery, source_recovery_exists,
      epoch_snapshot, "mark QP ERROR"
    );
  endfunction

  // 设计：持久化未由 backing cleanup 角色位表示的 destroy 里程碑（ERROR 转换、QPC_DELETE）。只替换
  //  detached recovery 快照，不改资源状态或任何带 authority 的身份。
  // 功能：校验并提交 ERROR QP 的恢复进度，经 recovery-only OCC 原子替换记录。
  // 输入/输出及副作用：qp_h、recovery 为输入；只更新 recovery_records，成功后推进 publication_epoch。
  // 失败/边界：非 QP、无 ERROR record、projection/validate 失败、保留的 authority 变化、epoch 过期、
  //  source 变化或 guard 忙时拒绝，不写回部分记录。
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
    status = rdma_resource_projector::project_qp_recovery_value(recovery,
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
        !rdma_resource_projector::same_mapping_value(recovery_copy.staging_mapping,
                            existing_recovery.staging_mapping) ||
        !rdma_resource_projector::same_mapping_value(recovery_copy.query_mapping,
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
    status = rdma_resource_projector::project_recovery_value(existing_record,
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

  // 设计：在后续操作丢弃不透明 release authority 之前保留恢复期分配的 query mapping。仅允许在 QP 已 ERROR
  //  且 record 尚无 query authority 时挂接一次，保证 query 分配失败可恢复，又不允许替换既有 mapping 身份。
  // 功能：在 ERROR QP 的 recovery record 中登记一次 query mapping，经 recovery-only OCC 原子替换。
  // 输入/输出及副作用：qp_h、query_mapping、query_mapping_recovery_only 为输入；成功只更新 recovery 账本。
  // 失败/边界：mapping 为空、非 ERROR QP、已有 query authority、projection/validate 失败、epoch/source
  //  变化或 guard 忙时拒绝，不留半成品 mapping。
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
      status = rdma_resource_projector::clone_recovery_mapping_value(
        query_mapping, "QP retained query recovery", projected_mapping);
    else
      status = rdma_resource_projector::clone_owned_mapping_value(
        query_mapping, "QP retained query", projected_mapping);
    if (!status.ok() || projected_mapping == null)
      return status.ok() ? rdma_status::make(
        RDMA_SC_INVALID_STATE, "QP retained query mapping projection failed") : status;
    status = rdma_resource_projector::project_recovery_value(existing_record,
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

  // 功能：按 role 取 QP plan 中对应的 backing ref，URC 角色在 urc_refs 中查找。
  // 输入/输出及副作用：plan、role 输入；只读，返回 ref（不转移所有权）。
  // 失败/边界：plan 为 null 或未命中返回 null。
  protected function rdma_qp_backing_ref qp_plan_ref(
    rdma_qp_backing_plan plan,
    rdma_queue_backing_role_e role
  );
    if (plan == null)
      return null;
    case (role)
      RDMA_QUEUE_ROLE_QP_SQ_RING: return plan.sq_ref;
      RDMA_QUEUE_ROLE_QP_SQ_SGB: return plan.sq_sgb_ref;
      RDMA_QUEUE_ROLE_QP_RQ_SGB: return plan.rq_sgb_ref;
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

  // 功能：判断某角色的自有 cleanup 是否已完成。
  // 输入/输出及副作用：plan、role 输入；只读，返回 bit。
  // 失败/边界：plan 为 null 返回 0；共享 SRQ 的 RQ 角色、无 ref 或非 CONTROL_PLANE 所有权视为已完成。
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

  // 功能：判断 role 的前驱 cleanup 角色是否都已完成（顺序 URC_DSQ→RDSQ→RSQ→RQ_PD→SQ_PD→RQ_RING→SQ_RING）。
  // 输入/输出及副作用：plan、role 输入；只读，返回 bit。
  // 失败/边界：URC_DSQ 无前驱恒为 1；其余按顺序依赖前驱的 qp_owned_cleanup_role_complete。
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
      // 可选 RQ-SGB 最后释放，不改变既有角色之间的顺序约束。
      RDMA_QUEUE_ROLE_QP_RQ_SGB:
        return urc_dsq_complete && urc_rdsq_complete && urc_rsq_complete &&
               rq_pd_complete && sq_pd_complete && rq_ring_complete &&
               qp_owned_cleanup_role_complete(plan, RDMA_QUEUE_ROLE_QP_SQ_RING) &&
               qp_owned_cleanup_role_complete(plan, RDMA_QUEUE_ROLE_QP_SQ_SGB);
      default:
        return 1'b0;
    endcase
  endfunction

  // 功能：在短 mutation guard 窗口内一次性写回已完成 projection 与 authority 校验的 recovery record。
  // 输入/输出及副作用：key、replacement、source_record、epoch_snapshot、operation 输入；成功只更新
  //  recovery_records[key] 并推进 publication_epoch，不调用 factory/adapter。
  // 失败/边界：key/record/source 缺失、validate 失败、epoch 过期、recovery 引用变化或 guard 忙时报错，
  //  不写部分记录；外部 projection 须在调用前完成。
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

  // 功能：recovery 已证明硬件缺失后，用 source/epoch 证据与 guard 原子删除 recovery entry。
  // 输入/输出及副作用：key、source_record、epoch_snapshot、operation 输入；成功只删 recovery_records[key]
  //  并推进 publication_epoch，不释放外部 mapping/backing（由调用方按 completion 契约处理）。
  // 失败/边界：key/source 缺失、epoch 过期、entry 被替换或 guard 忙时报错；未知 key 幂等成功。
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

  // 功能：把 registry resource 与可选 recovery record 作为同一 detached candidate 提交，统一 ERROR 转换、
  //  recovery 替换和 staged 标志的最终写回边界。
  // 输入/输出及副作用：replace_recovery/clear_recovery/clear_staged 选择 recovery/staged 的单向变化；
  //  成功只更新 manager 账本并推进 publication_epoch，不调用 factory/adapter。
  // 失败/边界：resource/recovery 缺失或 validate 失败、identity 改变、epoch/source 过期、recovery 存在性
  //  与 source 不符、replace/clear 同时置位或 guard 忙时报错，不留 ERROR-only 或 recovery-only 半提交。
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
    status = rdma_status::nonnull(
      replacement.validate(),
      {operation, " resource replacement validation returned null"}
    );
    if (!status.ok())
      return status;
    if (replace_recovery) begin
      status = rdma_status::nonnull(
        recovery_replacement.validate(),
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
             !rdma_resource_projector::same_handle_instance(registry[key].handle, replacement.handle))
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

  // 功能：为 QP flush/cleanup/context recovery 建立 registry/recovery 双账本 detached 快照。
  // 输入/输出及副作用：qp_h、operation 为输入；输出 key、两份副本、has_recovery、epoch_snapshot 和
  //  source 引用；只读投影，不取得外部 backing 所有权。
  // 失败/边界：非 QP、状态非 QUIESCING/ERROR、plan/recovery 缺失或投影失败返回错误并清空输出。
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
    status = rdma_resource_projector::project_resource_value(registry[key], {operation, " resource"},
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
      status = rdma_resource_projector::project_recovery_value(recovery_records[key],
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

  // 功能：在一次 mutation_guard 窗口内校验并同步发布 QP registry 与 recovery 进度，推进 epoch。
  // 输入/输出及副作用：快照、epoch、source、operation 为输入；成功仅更新 manager 自有账本。
  // 失败/边界：guard 忙、校验失败、epoch 过期或 source 引用变化返回错误，两份账本保持原值。
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

  // 功能：记录 QP 的 SQ ring/SQ PD/RQ PD role 的 flush 完成位，并同步更新两份进度账本。
  // 输入/输出及副作用：qp_h、role 为输入；经 qp_progress_snapshots 取快照后由 commit_qp_progress 提交。
  // 失败/边界：role 非法或快照/前置校验失败返回对应错误，拒绝时不提交部分进度。
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

  // 功能：记录 QP 的 payload/PD role 的 control-plane cleanup 完成位，并同步更新两份进度账本。
  // 输入/输出及副作用：qp_h、role 为输入；经 qp_progress_snapshots 取快照后由 commit_qp_progress 提交。
  // 失败/边界：role 非法、ref 缺失/已完成或 recovery 对不上时返回错误，拒绝时不提交部分进度。
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

  // 功能：记录 QP context 的释放完成位，并同步更新 registry 与 recovery 两份进度。
  // 输入/输出及副作用：qp_h 为输入；经 qp_progress_snapshots 取快照，校验 slot token 后提交进度。
  // 失败/边界：快照、context 或 token authority 校验失败时返回错误，拒绝时不提交部分进度。
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

  // 功能：判断 QP backing plan 的 flush/cleanup/context 释放是否都已完成。
  // 输入/输出及副作用：plan 为输入；经 query_*_release_completion 只读查询 adapter 完成证明；返回 bit。
  // 失败/边界：plan 为 null、任一里程碑/完成证明缺失或 ref 为 null 时返回 0。
  protected function bit qp_plan_cleanup_ready(rdma_qp_backing_plan plan);
    rdma_qp_backing_ref refs[$];
    rdma_queue_slot_token_contract token;
    rdma_status status;
    bit release_complete;

    if (plan == null)
      return 1'b0;
    // 部分编程前的 plan 可停在任意分配点：仅对已保留 authority 的 role 要求里程碑，
    // 缺失的后续 role 视为已完成。
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
      if (plan.rq_sgb_ref != null) refs.push_back(plan.rq_sgb_ref);
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

  // 功能：在空 QP reservation 或已完成 cleanup 后，原子删除本地 QP 资源并归还 QPN。
  // 输入/输出及副作用：qp_h 为 incarnation 键；admission 前冻结 epoch，核对 plan、context token、
  //  mapping 完成证明与依赖后，统一回收 registry/recovery/staged。
  // 失败/边界：非 QP、状态不允许、硬件未 ABSENT、cleanup 未完成、有依赖/outstanding、旧 epoch、
  //  ID 重复或 guard 忙均拒绝；不替 adapter 释放外部 backing。
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

  // 功能：为队列/QP 恢复进度建立 detached candidate，后续 role 检查与双快照提交共用同一组快照。
  // 输入/输出及副作用：handle、operation 为输入，candidate 为输出；只投影 registry/recovery，不写账本。
  // 失败/边界：非 QUIESCING/ERROR、plan 缺失、ERROR 缺 recovery 或 validate 失败时返回错误并清空 candidate。
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
    // 在 detached projection 前冻结 manager epoch 与 registry source；source 仅作非拥有 OCC 证据，
    // commit 时重新比较，避免外部窗口内的新 publication 被旧 candidate 覆盖。
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
    status = rdma_resource_projector::project_resource_value(
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
      status = rdma_resource_projector::project_recovery_value(
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

  // 功能：校验并原子发布 queue progress candidate，将 resource 与可选 ERROR recovery 同步写回。
  // 输入/输出及副作用：candidate、operation 为输入；成功在同一 guard 窗口更新两份账本并推进 epoch。
  // 失败/边界：guard 忙返回 RESOURCE_BUSY；candidate 不完整、validate 失败、epoch 过期或 source
  //  变化均拒绝且不写任何账本；operation 仅作诊断上下文。
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
    // 两份快照均已校验；持 mutation_guard 在唯一权威替换点一并发布。
    if (status.ok()) begin
      registry[candidate.key] = candidate.resource_copy;
      if (candidate.has_recovery)
        recovery_records[candidate.key] = candidate.recovery_copy;
      advance_publication_epoch();
    end
    mutation_guard.put(1);
    return status;
  endfunction

  // 设计：role 是逻辑身份而非数组位置；调用方须先证明 role 恰好出现一次才可使用返回的索引。
  // 功能：统计 flush_targets 中 role 出现次数，命中时输出索引。
  // 输入/输出及副作用：plan、role 为输入，target_index 为输出；只读，返回匹配数量。
  // 失败/边界：plan 为空或无非空 target 返回 0 且索引置 0；重复 role 时索引为最后命中，返回值非 1 不得用。
  protected function int unsigned queue_flush_role_count(
    rdma_queue_backing_plan plan,
    rdma_queue_backing_role_e role,
    output int unsigned target_index
  );
    return rdma_queue_role_cardinality_policy::count_flush_targets(
      plan, role, target_index
    );
  endfunction

  // 功能：统计 plan.refs 中 role 出现次数，命中时输出索引。
  // 输入/输出及副作用：plan、role 为输入，ref_index 为输出；只读，返回匹配数量。
  // 失败/边界：plan 为空或无非空 ref 返回 0 且索引置 0；重复 role 时索引为最后命中，返回值非 1 不得用。
  protected function int unsigned queue_ref_role_count(
    rdma_queue_backing_plan plan,
    rdma_queue_backing_role_e role,
    output int unsigned ref_index
  );
    return rdma_queue_role_cardinality_policy::count_backing_refs(
      plan, role, ref_index
    );
  endfunction

  // 设计：flush 进度同时存在于 authoritative 与 ERROR recovery 两份 plan，以 role 匹配；先确认本地
  //  role 唯一，再读 recovery target，最后经 commit_queue_progress 一次性发布，避免单侧完成位。
  // 功能：为指定 queue backing role 记录 flush 完成，校验前驱已完成，ERROR 时核对 PD mapping authority。
  // 输入/输出及副作用：handle、role 为输入；成功仅提交对应 flush_targets[*].flush_complete 位。
  // 失败/边界：handle/状态/plan 无效时传播状态；本地 role 缺失/重复/已完成返回 INVALID_ARGUMENT；
  //  recovery role/authority 不符或前驱未完成返回 INVALID_STATE；拒绝时不发布部分进度。
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
    // 在任何 recovery 比较解引用索引前先确认本地 role 唯一；缺失/重复属参数错误，
    // 不得被畸形 recovery 快照掩盖。
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
          !rdma_resource_projector::same_mapping_value(
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

  // 设计：cleanup 以 backing role 为身份；先建立本地唯一 ref 索引再比较 recovery，避免用未初始化下标。
  // 功能：为指定 queue backing role 记录 control-plane cleanup，并校验 SRQ SGB 所需的 SRFQ flush 前置。
  // 输入/输出及副作用：handle、role 为输入；成功经 commit_queue_progress 发布 refs[*].cleanup_complete。
  // 失败/边界：快照无效时传播状态；本地 role 缺失/重复/已清理/非 CONTROL_PLANE 返回 INVALID_ARGUMENT；
  //  recovery 不唯一、SRFQ flush 未完成或前驱不满足返回 INVALID_STATE；拒绝时进度不变。
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
    // 在任何 recovery 比较解引用索引前先确认本地 role 唯一；缺失/重复属参数错误，
    // 不得被畸形 recovery 快照掩盖。
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

  // 功能：为 QUIESCING/ERROR 的 CQ/SRQ/CEQ/AEQ 记录 context backing 的释放完成位。
  // 输入/输出及副作用：handle 为输入；在两份 candidate 的 context_ref 上置 release_complete 后提交。
  // 失败/边界：handle/状态/plan 无效、context 缺失或已完成返回 INVALID_ARGUMENT/INVALID_STATE；
  //  ERROR 路径 context authority 与 recovery 不一致时拒绝，commit 前不改动账本。
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
    // context 释放是 cleanup recipe 的第一项本地动作，完成位须独立记录；SRQ payload role 随后才释放，
    // 故此处不能要求 SGB progress，否则会倒置 recipe 顺序或使 recovery 丢失可重放证据。
    resource_queue.queue_plan.context_ref.release_complete = 1'b1;
    if (progress.has_recovery) begin
      recovery_context.release_complete = 1'b1;
    end
    return commit_queue_progress(progress, "queue context progress");
  endfunction

  // 功能：ACTIVE 替换发布瞬间的受保护观察点，供派生 manager 审计 prepared recovery 元数据。
  // 输入/输出及副作用：prepared_recovery 为输入；默认空实现，不得延长其生命周期或改变发布顺序。
  // 失败/边界：无。
  protected virtual function void queue_restore_pre_publish_observer(
    rdma_recovery_record prepared_recovery
  );
  endfunction

  // 功能：最终 validate 之前观察 detached queue replacement 的受保护钩子。
  // 输入/输出及副作用：prepared_resource 为输入；默认空实现，不向调用方暴露 live registry/recovery 对象。
  // 失败/边界：无。
  protected virtual function void queue_restore_pre_validate_observer(
    rdma_resource prepared_resource
  );
  endfunction

  // 设计：MR 进入 ERROR 后仅当硬件仍存在、无待执行破坏性步骤、registry 与 recovery 共享同一
  //  backing/HMC authority 时才能恢复 ACTIVE；opaque release query 只在此读取 adapter 完成事实。
  // 功能：按 restore_active 原有拒绝顺序校验 MR ERROR recovery 的硬件、进度、backing/HMC authority。
  // 输入/输出及副作用：authoritative、recovery 为只读快照；经 query_owned_release_completion 读完成证明；
  //  不修改任何账本，返回 rdma_status。
  // 失败/边界：调用方须先确认 key、MR 类型与 recovery 已登记；各拒绝分支保持原错误文本与顺序，
  //  owned backing 已释放或 opaque query 为 null/失败/complete 时拒绝。
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
          !rdma_resource_projector::same_mapping_value(
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
          !rdma_resource_projector::same_mapping_handle_value(
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

  // 设计：queue 进入 ERROR 后仅当硬件仍存在、无本地破坏性 cleanup、registry 与 recovery 共享同一
  //  backing/context authority 时才能恢复 ACTIVE；本函数只读证明，发布仍由 restore_active 负责。
  // 功能：按 restore_active 原有拒绝顺序校验 lifecycle queue ERROR recovery 的 shape 与 authority。
  // 输入/输出及副作用：authoritative、recovery 为只读快照；经 query_owned_release_completion 读完成证明；
  //  不修改账本、plan 或 SRQ flush progress。
  // 失败/边界：调用方须先完成 staged/recovery 存在性门禁；依次检查 recovery plan、破坏性 cleanup、
  //  各 role 唯一匹配与 mapping/HMC authority，首错即返回 INVALID_STATE；成功返回 success。
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

  // 设计：SRQ 恢复时旧 destroy 可能只完成部分 flush；只清 detached candidate 上的进度位，
  //  registry 中的 authority 待 candidate validate 成功后一次性替换，不在 admission 阶段回退。
  // 功能：把 SRQ backing plan 的全部 flush target 重置为未完成，使下次 destroy 重新完整 flush。
  // 输入/输出及副作用：plan 为调用方拥有的 detached candidate，原地清零 flush_complete。
  // 失败/边界：调用方须保证 plan 与各 flush target 非空且属 SRQ；本函数不校验、不返回 status。
  protected function void clear_srq_flush_progress(
    rdma_queue_backing_plan plan
  );
    foreach (plan.flush_targets[i])
      plan.flush_targets[i].flush_complete = 1'b0;
  endfunction

  // 功能：把安全的 QUIESCING 资源，或 recovery authority 完整的 ERROR MR/lifecycle queue，恢复为新的 ACTIVE。
  // 输入/输出及副作用：handle 为查找键；成功覆盖 registry[key]，ERROR 路径同 guard 内删 recovery 并推进
  //  epoch；SRQ candidate 的 flush 进度清零；不释放外部 backing。
  // 失败/边界：lookup/schema、staged、authority、投影、validate、状态或 epoch/source 门禁失败即拒绝；
  //  guard 忙返回 RESOURCE_BUSY；非 MR/lifecycle queue 的 ERROR 资源被拒绝，拒绝不删除恢复证据。
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
    // lookup 不回写 registry；schema 只规范化 recovery。先冻结代际与 resource，再刷新规范化后的
    // recovery 引用，使后续 authority/clone/observer 窗口均受 OCC 保护。
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
        status = rdma_resource_projector::project_recovery_value(recovery, "restore queue recovery",
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
        status = rdma_status::nonnull(
          recovery_replacement.validate(),
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
    status = rdma_resource_projector::project_resource_value(registry[key], "restore active",
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
      status = rdma_resource_projector::project_queue_plan_value(recovery_replacement.queue_plan,
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
    // pre-delete SRQ flush 失败可能已置位首个进度位；仅在明确无变化的失败时允许恢复 ACTIVE，
    // 并须清除全部 pre-delete 进度，使下次 destroy 从干净 authority 重试两条命令。
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
    status = rdma_status::nonnull(
      replacement.validate(),
      "restored resource validation returned null"
    );
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

  // 设计：ERROR 重发布只认可观察的 durable progress 变化；identity/authority 已由 caller 校验，
  //  故不能用完整 recovery 比较代替资源等价判断。
  // 功能：比较两份 ERROR recovery 的 step 序列、rollback 数量及 queue refs/flush/context 完成位。
  // 输入/输出及副作用：lhs、rhs 为只读引用；返回 bit，不改账本；rollback status 内容不参与比较。
  // 失败/边界：任一为 null、step/rollback 数量或内容、refs/flush 数量或完成位、context 状态不同返回 0；
  //  两侧 plan 均为 null 时在 step 比较通过后返回 1。
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

  // 功能：校验并合并 MR/queue 恢复证据，把 ERROR resource、recovery 与 staged 清除作为一次双账本提交。
  // 输入/输出及副作用：handle 定位 incarnation，recovery 为 caller 候选；reserved_only 限定未 staged 的
  //  ALLOCATED MR 本地回滚；成功推进 epoch，不做外部释放。
  // 失败/边界：QP、畸形身份、recovery 不匹配、非 canonical reservation、完成证明不符、plan/role 错误、
  //  无进度重放、投影失败、epoch/source 变化或 guard 忙均拒绝，不发布半成品。
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

    status = rdma_resource_projector::project_handle_value(handle, "mark error", trusted_handle);
    if (!status.ok())
      return status;
    if (trusted_handle != null &&
        trusted_handle.kind == RDMA_RESOURCE_QP)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "QP resources require QP-specific ERROR publication"
      );
    status = rdma_resource_projector::project_public_recovery_value(recovery, "mark error",
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
    status = rdma_resource_projector::project_resource_value(registry[key], "mark error registry",
                                    replacement);
    if (!status.ok())
      return status;
    if (replacement.handle == null ||
        !rdma_resource_projector::same_handle_instance(replacement.handle, trusted_handle))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "error registry identity is inconsistent");
    if (recovery_copy.resource_h == null ||
        !rdma_resource_projector::same_handle_instance(recovery_copy.resource_h, trusted_handle))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "recovery record does not match the resource incarnation"
      );
    status = rdma_status::nonnull(recovery_copy.validate(), "recovery validation returned null");
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
              !rdma_resource_projector::same_handle_instance(
                recovery_copy.queue_plan.refs[i].mapping.function_h,
                queue_replacement.owner
              ) ||
              (recovery_copy.queue_plan.refs[i].ownership ==
                 RDMA_OWNERSHIP_CONTROL_PLANE &&
               !rdma_resource_projector::same_handle_instance(
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
                !rdma_resource_projector::same_handle_instance(
                  recovery_copy.queue_plan.refs[i].additional_segments[j].
                    mapping.function_h,
                  queue_replacement.owner
                ) ||
                (recovery_copy.queue_plan.refs[i].additional_segments[j].
                   ownership == RDMA_OWNERSHIP_CONTROL_PLANE &&
                 !rdma_resource_projector::same_handle_instance(
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
            !rdma_resource_projector::same_handle_instance(
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
        status = rdma_status::nonnull(
          rdma_resource_projector::project_queue_plan_value(
              recovery_copy.queue_plan, "mark error transaction resource plan",
              authoritative_plan
            ),
          "transaction resource plan projection returned null"
        );
        if (!status.ok())
          return status;
        status = rdma_status::nonnull(
          rdma_resource_projector::project_queue_plan_value(
              recovery_copy.queue_plan, "mark error transaction recovery plan",
              recovery_plan
            ),
          "transaction recovery plan projection returned null"
        );
        if (!status.ok())
          return status;
        queue_replacement.queue_plan = authoritative_plan;
        queue_replacement.depth = authoritative_plan.rings[0].depth;
        recovery_copy.queue_plan = recovery_plan;
        replacement = queue_replacement;
      end
      else if (reservation_release_recovery) begin
        // reservation-only queue rollback 先在 ALLOCATED 下持久化，mark_error() 发布 ERROR 记录后可能重试；
        // 此处继续接受该 canonical 快照，使后续 recovery 能原子消费 RESOURCE_RELEASED，否则已清理的
        // ambiguous create 将永久卡住。
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
        status = rdma_status::nonnull(
          rdma_resource_projector::project_queue_plan_value(
              recovery_copy.queue_plan,
              "mark error reservation resource plan", authoritative_plan
            ),
          "reservation resource plan projection returned null"
        );
        if (!status.ok())
          return status;
        status = rdma_status::nonnull(
          rdma_resource_projector::project_queue_plan_value(
              recovery_copy.queue_plan,
              "mark error reservation recovery plan", recovery_plan
            ),
          "reservation recovery plan projection returned null"
        );
        if (!status.ok())
          return status;
        queue_replacement.queue_plan = authoritative_plan;
        queue_replacement.depth = authoritative_plan.rings[0].depth;
        recovery_copy.queue_plan = recovery_plan;
        replacement = queue_replacement;
      end
      else begin
        // QUIESCING 进度仅存于 registry；ERROR recovery 开始时以其为权威，防止调用方用旧 plan 抹掉已证明的 cleanup。
        status = rdma_status::nonnull(
          rdma_resource_projector::project_queue_plan_value(
              queue_replacement.queue_plan,
              "mark error authoritative queue plan", authoritative_plan
            ),
          "queue ERROR plan projection returned null"
        );
        if (!status.ok())
          return status;
        recovery_copy.queue_plan = authoritative_plan;
      end
      status = rdma_status::nonnull(
        recovery_copy.validate(),
        "merged queue recovery validation returned null"
      );
      if (!status.ok())
        return status;
    end
    replacement.state = RDMA_RESOURCE_ERROR;
    status = rdma_status::nonnull(
      replacement.validate(),
      "ERROR resource validation returned null"
    );
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

  // 功能：发布普通资源的 ERROR 与持久恢复证据，委托 mark_error_transition。
  // 输入/输出及副作用：handle、recovery 为输入；成功原子更新 registry/recovery 并清 staged。
  // 失败/边界：拒绝 QP、未 staged 的 ALLOCATED MR、错误 authority/plan、旧快照或锁忙；状态原样返回。
  virtual function rdma_status mark_error(
    rdma_handle handle,
    rdma_recovery_record recovery
  );
    return mark_error_transition(handle, recovery, 1'b0);
  endfunction

  // 功能：把尚未 staged 的 MR reservation 转为可重试的本地 ERROR。
  // 输入/输出及副作用：handle、recovery 为输入；成功以双账本提交保留 backing cleanup 证据。
  // 失败/边界：非 ALLOCATED MR、已 staged、硬件非 ABSENT、ticket/HMC 不符、非单步本地 cleanup、
  //  owned seal/completion 不符、快照过期或锁忙均拒绝且不半提交。
  virtual function rdma_status mark_reserved_error(
    rdma_handle handle,
    rdma_recovery_record recovery
  );
    return mark_error_transition(handle, recovery, 1'b1);
  endfunction

  // 功能：完成 mark_reserved_error 保留的 MR 本地 rollback：adapter 证明 backing 已释放后删除资源与恢复记录并归还 local ID。
  // 输入/输出及副作用：handle 为 ERROR MR 键；外部窗口前冻结 epoch；成功提交 manager 账本，不再释放 backing。
  // 失败/边界：非 unstaged ERROR MR、硬件历史/非 ABSENT、ticket/HMC 不符、非单个 owned backing、
  //  completion 不符、有依赖/在途操作、旧 epoch 或锁忙均拒绝。
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
    // 公开的 RELEASED 状态可被伪造；完成仅以 adapter 封存且与 canonical recovery mapping 共享的事实为准。
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

  // 功能：按完整 handle 查找 recovery 记录并返回 detached 快照。
  // 输入/输出及副作用：handle 为输入，recovery 为输出（先置 null）；只读，不暴露内部对象。
  // 失败/边界：lookup/schema 失败传播；无 recovery 记录返回 INVALID_STATE。
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
    return rdma_resource_projector::project_recovery_value(recovery_records[key], "lookup recovery",
                                recovery);
  endfunction

  // 功能：ERROR 资源硬件缺失且 pending 清空后删除其 recovery 记录。
  // 输入/输出及副作用：handle 为资源键；冻结 source/epoch 后检查 recovery_ready，成功仅删 recovery 并推进 epoch。
  // 失败/边界：lookup/schema 失败、非 ERROR、无 recovery、未就绪、旧 source/epoch 或 guard 忙均拒绝并保留证据。
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

  // 功能：为 QUIESCING 或恢复就绪的 ERROR 普通资源执行最终本地释放。
  // 输入/输出及副作用：handle 指定 incarnation；admission 前冻结 epoch，成功原子删除 registry/recovery/staged、
  //  归还 local ID，不接管外部 backing。
  // 失败/边界：Function/QP 须走专用入口；非 closing 状态、recovery 未就绪、有依赖/outstanding、
  //  schema/lookup 失败、epoch 变化、ID 重复或 guard 忙均不提交。
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

  // 功能：回收 ALLOCATED reservation，或 canonical queue reservation rollback 已完成的 ERROR 资源。
  // 输入/输出及副作用：handle 为资源键；admission 前冻结 epoch，成功原子清理 registry/recovery/staged 和
  //  local-ID pool，不释放外部 backing；依赖检查先于 outstanding 检查。
  // 失败/边界：Function、有 plan/QPC 的 QP、非法状态、recovery 缺失/不符、依赖/outstanding、旧 epoch、
  //  ID 冲突或锁忙均拒绝。
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

  // 功能：在 ACTIVE resource 的 detached 快照追加 outstanding operation ID 并经 OCC helper 发布。
  // 输入/输出及副作用：handle、outstanding_id 为输入；成功更新 registry 并推进 epoch。
  // 失败/边界：ID 为零/重复、非 ACTIVE、投影/validate 失败、epoch/source 变化或 guard 忙时拒绝，ledger 不变。
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
    status = rdma_resource_projector::project_resource_value(registry[key], "track outstanding",
                                  replacement);
    if (!status.ok())
      return status;
    replacement.outstanding_ids.push_back(outstanding_id);
    return commit_registry_replacement(
      key, replacement, "track outstanding",
      epoch_snapshot, source_resource
    );
  endfunction

  // 功能：从 ACTIVE resource 的 outstanding ledger 删除一个已完成 operation ID 并经 OCC helper 发布。
  // 输入/输出及副作用：handle、outstanding_id 为输入；成功更新 registry 并推进 epoch。
  // 失败/边界：目标/ID 未知、投影/validate 失败、epoch/source 变化或 guard 忙时拒绝，ledger 不变。
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
    status = rdma_resource_projector::project_resource_value(registry[key], "retire outstanding",
                                  replacement);
    if (!status.ok())
      return status;
    replacement.outstanding_ids.delete(found_index);
    return commit_registry_replacement(
      key, replacement, "retire outstanding",
      epoch_snapshot, source_resource
    );
  endfunction

  // 功能：lookup 资源后调用 commit_programmed，把资源提交为已编程状态。
  // 输入/输出及副作用：handle 为输入；副作用由 commit_programmed 决定。
  // 失败/边界：lookup 失败时原样返回其 status。
  function rdma_status freeze(rdma_handle handle);
    rdma_resource candidate;
    rdma_status status;

    status = lookup(handle, candidate);
    if (!status.ok())
      return status;
    return commit_programmed(candidate);
  endfunction

  // 功能：兼容入口，仅回收尚未编程且无依赖的 ALLOCATED 普通资源。
  // 输入/输出及副作用：handle 为资源键；schema/lookup 前冻结 epoch，成功原子移除资源与辅助账本并归还
  //  local ID；保留 incarnation tombstone，外部 backing 由 caller 管理。
  // 失败/边界：Function、ERROR、非 ALLOCATED、有依赖、schema/lookup 失败、旧 epoch、ID 冲突或 guard 忙均拒绝；
  //  QP 仍应走专用 finalization。
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

  // 功能：为精确 Function generation 计算依赖逆序 teardown 集合，一次提交全部释放并退休 generation。
  // 输入/输出及副作用：owner 为非拥有 Function handle；成功删除所属 registry/recovery/staged、归还 local ID、
  //  标记 retired 并推进一次 epoch；保留 incarnation tombstone。
  // 失败/边界：空/错误 owner、未知代际、已 retired、schema 失败、依赖环、epoch 变化、ID 重复/越界或 guard 忙
  //  均拒绝；不调用外部硬件释放，caller 须先静默。
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
    status = rdma_resource_projector::project_function_handle_value(owner, "Function teardown",
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
          rdma_resource_projector::same_handle_instance(registry[key].owner, trusted_owner))
        target_count++;
    end

    while (release_order.size() < target_count) begin
      progress = 1'b0;
      foreach (registry[key]) begin
        if (selected.exists(key) || registry[key].owner == null ||
            !rdma_resource_projector::same_handle_instance(registry[key].owner, trusted_owner))
          continue;
        blocked = 1'b0;
        foreach (registry[other_key]) begin
          if (key == other_key || selected.exists(other_key) ||
              registry[other_key].owner == null ||
              !rdma_resource_projector::same_handle_instance(registry[other_key].owner,
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

  // 功能：统计 registry 中残留资源数，可按 owner Function 过滤。
  // 输入/输出及副作用：leak_count 输出残留数；owner 为 null 时统计全部；只读。
  // 失败/边界：owner 非 Function handle 返回 INVALID_ARGUMENT；schema 失败传播；leak_count 非零返回 INVALID_STATE。
  function rdma_status check_leaks(
    output int unsigned leak_count,
    input rdma_function_handle owner = null
  );
    rdma_function_handle trusted_owner;
    rdma_status status;

    leak_count = 0;
    trusted_owner = null;
    if (owner != null) begin
      status = rdma_resource_projector::project_function_handle_value(owner, "leak filter",
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
           rdma_resource_projector::same_handle_instance(registry[key].owner, trusted_owner)))
        leak_count++;
    end
    if (leak_count != 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               $sformatf("%0d RDMA resources leaked",
                                         leak_count));
    return rdma_status::success();
  endfunction
endclass
