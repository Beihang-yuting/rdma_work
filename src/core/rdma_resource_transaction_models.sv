// 目录/层次：核心执行层 core/rdma_resource_transaction_models.sv。
// 文件职责：定义 resource manager 在 identity 预留阶段使用的 detached transaction candidate，
//   把分配结果与回滚证据从 create_* 业务中分离。
// 主要依赖：rdma_types_pkg 的资源 kind/handle 与 rdma_model_pkg 的 Function handle；不访问
//   registry、allocator 数组或 adapter。
// 所有权与生命周期：candidate 仅在一次 reserve→publish/rollback 窗口内归 resource manager；
//   不复制 mutable ledger、锁、registry 或 reset authority，提交后由调用方丢弃。

// 设计说明：identity candidate 是 transaction 值，不是新的 allocator owner。manager 仍在
//   reserve_identity() 内更新 next_local_id/free_local_ids/serial 与 binding registration；
//   candidate 只携带撤销所需的 detached 参数，避免各 create_* 重复声明并错配回滚参数。
// 生命周期 admission 用同一份只读快照传递“依赖仍存”与“操作在途”，只保存扫描结果，不缓存 registry。
typedef struct {
  bit has_live_dependents;
  bit has_outstanding_operations;
  bit has_qp_dependents;
  bit has_srq_dependents;
  bit has_non_qp_dependents;
  bit has_qp_dependents_with_outstanding;
  int unsigned dependent_count;
  int unsigned qp_dependent_count;
  int unsigned srq_dependent_count;
  int unsigned dependent_with_outstanding_count;
  int unsigned outstanding_count;
} rdma_resource_activity_blocker_snapshot;

// 设计说明：candidate 同时携带 registry 快照、ERROR recovery 快照与唯一 resource key，避免多个
//   output 参数错配；只收束 detached 值，不提交，manager 仍是两份账本的唯一 owner。
class rdma_queue_progress_candidate;
  string key;
  rdma_resource resource_copy;
  rdma_recovery_record recovery_copy;
  // manager_epoch 与 source_* 是 snapshot→commit 的 OCC 证据：candidate 只持有账本对象的非拥有
  // 引用，commit 前须确认仍是同一条目，不允许旧快照覆盖调用窗口内的新状态。
  longint unsigned manager_epoch;
  rdma_resource source_resource;
  rdma_recovery_record source_recovery;
  bit has_recovery;

  // 功能：构造空的 queue progress candidate。
  // 输入/输出及副作用：name 为对象名；key、快照、epoch 与 source 引用均清空，须由 manager 填充。
  // 失败/边界：默认 candidate 不可提交。
  function new(string name = "rdma_queue_progress_candidate");
    key = "";
    resource_copy = null;
    recovery_copy = null;
    manager_epoch = '0;
    source_resource = null;
    source_recovery = null;
    has_recovery = 1'b0;
  endfunction

  // 功能：判断 candidate 是否具备 queue progress 提交所需的 detached 形态。
  // 输入/输出及副作用：只读 key/resource_copy/recovery_copy/has_recovery，返回 bit；OCC 证据由 commit 校验。
  // 失败/边界：key 或 resource_copy 为空返回 0；has_recovery 为真而 recovery_copy 为空返回 0。
  function bit valid();
    return key != "" && resource_copy != null &&
           (!has_recovery || recovery_copy != null);
  endfunction

  // 功能：清空 candidate，防止重复提交。
  // 输入/输出及副作用：断开快照与 OCC source 引用并恢复默认值；不改 manager registry。
  // 失败/边界：幂等；不回滚，需回滚须在 clear 前由调用方完成。
  function void clear();
    key = "";
    resource_copy = null;
    recovery_copy = null;
    manager_epoch = '0;
    source_resource = null;
    source_recovery = null;
    has_recovery = 1'b0;
  endfunction
endclass

class rdma_resource_identity_candidate;
  rdma_resource_kind_e kind;
  rdma_function_handle owner;
  rdma_handle handle;
  // manager_epoch 为 reserve_identity 完成时的 manager 代际；create_* 在外部调用窗口返回后必须
  // 重新核对，防止旧 reservation 与新 registry publication 拼接。
  longint unsigned manager_epoch;
  int unsigned local_id;
  int unsigned prior_serial;
  bit used_free_id;
  bit registered_binding;

  // 功能：构造空的 identity candidate。
  // 输入/输出及副作用：name 为对象名；所有分配与回滚字段清零。
  // 失败/边界：默认 candidate 不是有效 reservation。
  function new(string name = "rdma_resource_identity_candidate");
    kind = RDMA_RESOURCE_FUNCTION;
    owner = null;
    handle = null;
    manager_epoch = '0;
    local_id = '0;
    prior_serial = '0;
    used_free_id = 1'b0;
    registered_binding = 1'b0;
  endfunction

  // 功能：判断 identity candidate 是否含 reserve_identity 成功后的完整证据。
  // 输入/输出及副作用：只读 kind/owner/handle，返回 bit。
  // 失败/边界：owner/handle 为空、kind 为 FUNCTION 或 handle.kind 与 kind 不一致返回 0。
  function bit valid();
    return owner != null && handle != null &&
           kind != RDMA_RESOURCE_FUNCTION &&
           handle.kind == kind;
  endfunction

  // 功能：清除 reservation 证据，防止二次提交。
  // 输入/输出及副作用：清零全部字段并断开 owner/handle 引用；不改 manager。
  // 失败/边界：幂等；不自动回滚，须先调用 rollback_identity_candidate()。
  function void clear();
    kind = RDMA_RESOURCE_FUNCTION;
    owner = null;
    handle = null;
    manager_epoch = '0;
    local_id = '0;
    prior_serial = '0;
    used_free_id = 1'b0;
    registered_binding = 1'b0;
  endfunction
endclass

// 设计说明：Function 创建同时建立 binding、Function resource 与 release tombstone，不能复用
//   普通对象的 serial 回滚规则；本 candidate 只携带该专用路径的 owner/binding 与 local-ID 回滚证据。
class rdma_function_identity_candidate;
  rdma_function_handle owner;
  rdma_handle handle;
  rdma_function_binding trusted_binding;
  string owner_key;
  // manager_epoch 为 Function generation reservation 完成后的 mutation epoch，供 create_function
  // 在 binding projection 返回后拒绝过期 identity。
  longint unsigned manager_epoch;
  int unsigned local_id;
  bit used_free_id;
  bit registered_binding;

  // 功能：构造空的 Function identity candidate。
  // 输入/输出及副作用：name 为对象名；owner、binding、local-ID 与回滚证据清空。
  // 失败/边界：默认 candidate 不是有效 reservation。
  function new(string name = "rdma_function_identity_candidate");
    owner = null;
    handle = null;
    trusted_binding = null;
    owner_key = "";
    manager_epoch = '0;
    local_id = '0;
    used_free_id = 1'b0;
    registered_binding = 1'b0;
  endfunction

  // 功能：判断 Function candidate 是否含专用 reserve_identity 路径的完整值。
  // 输入/输出及副作用：只读 owner/handle/trusted_binding/owner_key，返回 bit。
  // 失败/边界：任一缺失、owner/handle 非 FUNCTION 或 owner_key 为空返回 0。
  function bit valid();
    return owner != null && handle != null && trusted_binding != null &&
           owner.kind == RDMA_RESOURCE_FUNCTION &&
           handle.kind == RDMA_RESOURCE_FUNCTION &&
           owner_key != "";
  endfunction

  // 功能：清除 Function candidate 的 reservation 证据。
  // 输入/输出及副作用：清零全部字段；不改 manager registry、allocator 或 generation ledger。
  // 失败/边界：幂等；撤销账本须先调用 rollback_function_identity_candidate()。
  function void clear();
    owner = null;
    handle = null;
    trusted_binding = null;
    owner_key = "";
    manager_epoch = '0;
    local_id = '0;
    used_free_id = 1'b0;
    registered_binding = 1'b0;
  endfunction
endclass

// 设计说明：publication candidate 把 register_resource() 中可能触发 factory/clone 的投影阶段
//   与 registry/代际账本提交阶段分开；只存值快照与稳定 key，不拥有 manager 账本，
//   commit 窗口内无需第二次外部调用。
class rdma_resource_publication_candidate;
  string registry_key;
  string incarnation_key;
  string generation_key;
  // manager_epoch 为 stage 时的 publication/allocator 代际；commit 只接受同一代 candidate，
  // 防止并发 mutation 让旧快照覆盖新状态。
  longint unsigned manager_epoch;
  rdma_resource registry_copy;
  rdma_resource published;
  rdma_function_handle owner_copy;
  rdma_handle handle_copy;

  // 功能：构造空的 publication candidate。
  // 输入/输出及副作用：name 为对象名；key 与投影引用清空，供 manager 在 stage→commit 窗口填充。
  // 失败/边界：默认 candidate 不可提交。
  function new(string name = "rdma_resource_publication_candidate");
    registry_key = "";
    incarnation_key = "";
    generation_key = "";
    manager_epoch = '0;
    registry_copy = null;
    published = null;
    owner_copy = null;
    handle_copy = null;
  endfunction

  // 功能：判断 publication candidate 的快照、owner/handle 与三类 key 是否完整且互相一致。
  // 输入/输出及副作用：只读字段，返回 bit；key 格式与 manager 的 canonical 格式一致。
  // 失败/边界：快照或 key 为空、kind 不符/未注册、owner/handle identity 不一致或 key 无法重算
  //   时返回 0；commit 不得猜测 owner、修补 key 或重新投影。
  function bit valid();
    return registry_copy != null && published != null &&
           owner_copy != null && handle_copy != null &&
           registry_copy.owner != null && published.owner != null &&
           registry_copy.handle != null && published.handle != null &&
           registry_key == $sformatf(
             "%016h:%08h:%01h:%08h",
             handle_copy.function_uid, handle_copy.generation,
             handle_copy.kind, handle_copy.object_id
           ) &&
           incarnation_key == $sformatf(
             "%016h:%08h:%01h:%08h",
             handle_copy.function_uid, handle_copy.generation,
             handle_copy.kind, handle_copy.object_id
           ) &&
           generation_key == $sformatf(
             "%016h:%08h:%08h",
             owner_copy.function_uid, owner_copy.object_id,
             owner_copy.generation
           ) &&
           owner_copy.kind == RDMA_RESOURCE_FUNCTION &&
           handle_copy.kind inside {RDMA_RESOURCE_FUNCTION, RDMA_RESOURCE_PD,
                                    RDMA_RESOURCE_MR, RDMA_RESOURCE_CQ,
                                    RDMA_RESOURCE_QP, RDMA_RESOURCE_SRQ,
                                    RDMA_RESOURCE_CMQ, RDMA_RESOURCE_CEQ,
                                    RDMA_RESOURCE_AEQ} &&
           registry_copy.owner.kind == RDMA_RESOURCE_FUNCTION &&
           published.owner.kind == RDMA_RESOURCE_FUNCTION &&
           registry_copy.handle.kind == handle_copy.kind &&
           published.handle.kind == handle_copy.kind &&
           registry_copy.handle.function_uid == handle_copy.function_uid &&
           registry_copy.handle.object_id == handle_copy.object_id &&
           registry_copy.handle.generation == handle_copy.generation &&
           published.handle.function_uid == handle_copy.function_uid &&
           published.handle.object_id == handle_copy.object_id &&
           published.handle.generation == handle_copy.generation &&
           owner_copy.function_uid == handle_copy.function_uid &&
           owner_copy.generation == handle_copy.generation &&
           registry_copy.owner.function_uid == owner_copy.function_uid &&
           registry_copy.owner.object_id == owner_copy.object_id &&
           registry_copy.owner.generation == owner_copy.generation &&
           published.owner.function_uid == owner_copy.function_uid &&
           published.owner.object_id == owner_copy.object_id &&
           published.owner.generation == owner_copy.generation;
  endfunction

  // 功能：丢弃 stage 产生的快照与 key，防止重复提交。
  // 输入/输出及副作用：清空全部字段；不删 registry，不回滚 allocator。
  // 失败/边界：幂等；撤销 identity reservation 须先执行 manager 的 rollback helper。
  function void clear();
    registry_key = "";
    incarnation_key = "";
    generation_key = "";
    manager_epoch = '0;
    registry_copy = null;
    published = null;
    owner_copy = null;
    handle_copy = null;
  endfunction
endclass
