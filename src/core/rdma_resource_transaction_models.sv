// 目录/层次：核心执行层 core/rdma_resource_transaction_models.sv。
// 文件职责：定义 resource manager 在 identity 预留阶段使用的 detached transaction candidate，
//   把分配结果和精确回滚证据从 create_* 业务构造中分离出来。
// 主要依赖：依赖 rdma_types_pkg 的资源 kind/handle 与 rdma_model_pkg 的 Function handle；
//   不访问 registry、allocator 数组或外部 adapter。
// 所有权与生命周期：candidate 仅由 rdma_resource_manager 在一次 reserve→publish/rollback
//   窗口内拥有；它不复制 mutable ledger、锁、registry 或 reset authority，提交后由调用方丢弃。

// 设计说明：identity candidate 是 L3 transaction 值，不是新的 allocator owner。
//   manager 仍在 reserve_identity() 内更新 next_local_id/free_local_ids/serial 和 binding
//   registration；candidate 只携带撤销这些更新所需的 detached 参数，避免每个 create_*
//   入口重复声明并错配 rollback 参数。
// 资源生命周期 admission 还需要把“依赖仍存”和“操作仍在途”作为同一份只读观察值传递。
// 这个结构只保存 manager 当前扫描结果，不缓存 registry，也不承担任何提交职责。
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

// 设计说明：queue progress 需要同时携带 registry 快照、ERROR recovery 快照和
// 唯一 resource key。过去由 manager 的多个 output 参数分别传递，调用方容易把
// has_recovery、key 与对应快照错配。candidate 只收束 detached 值，不执行任何
// registry/recovery 提交；manager 仍是两份 mutable 账本的唯一 owner。
class rdma_queue_progress_candidate;
  string key;
  rdma_resource resource_copy;
  rdma_recovery_record recovery_copy;
  // manager_epoch 与 source_* 是 snapshot→commit 的 OCC 证据。candidate 只保存
  // manager 当时账本对象的非拥有引用；commit 前必须重新确认它们仍是同一条目，
  // 不允许旧 recovery/resource 快照覆盖外部调用窗口内的新状态。
  longint unsigned manager_epoch;
  rdma_resource source_resource;
  rdma_recovery_record source_recovery;
  bit has_recovery;

  // 功能：构造一个未绑定 queue progress 的 detached candidate，清空 key、快照和
  // recovery presence 标记和 OCC 证据，供 resource manager 在一次 snapshot→commit 窗口内填充。
  // 输入/输出及副作用：name（输入）仅用于对象命名；构造函数不读取 registry、
  // recovery_records、锁或外部 backing，也不取得任何资源所有权；epoch 与 source 引用
  // 初始为空，必须由 manager 的 snapshot 阶段安装。
  // 失败/边界：默认 candidate 不可提交；必须由 manager 填入非空 key/resource_copy，
  // 且 has_recovery 为真时还要填入 recovery_copy，部分值不得绕过 manager 校验。
  function new(string name = "rdma_queue_progress_candidate");
    key = "";
    resource_copy = null;
    recovery_copy = null;
    manager_epoch = '0;
    source_resource = null;
    source_recovery = null;
    has_recovery = 1'b0;
  endfunction

  // 功能：判断 candidate 是否具备 queue progress 提交所需的 detached shape，避免
  // caller 在快照不完整时进入 role/authority 解引用或 publication。
  // 输入/输出及副作用：函数只读取 key、resource_copy、recovery_copy 和 has_recovery，
  // 返回 bit；OCC source/epoch 由 commit 单独校验，不修改 candidate、manager 账本或
  // 外部资源。
  // 失败/边界：key 为空或 resource_copy 为空时返回 0；has_recovery 为真而 recovery_copy
  // 为空同样返回 0；无 recovery 的 QUIESCING candidate 可以合法保持 recovery_copy=null。
  function bit valid();
    return key != "" && resource_copy != null &&
           (!has_recovery || recovery_copy != null);
  endfunction

  // 功能：清除 queue progress candidate 的 key、快照、OCC source/epoch 和 recovery 标记，使 snapshot
  // 或 commit 完成后同一对象不能被重复提交。
  // 输入/输出及副作用：函数断开 candidate 对 detached resource/recovery 及 OCC source
  // 的引用并恢复默认值；不删除 manager registry，不回滚已发布状态，也不释放外部 backing。
  // 失败/边界：对默认或已清除 candidate 幂等；如需回滚 manager 状态，调用方必须在
  // clear 前显式执行对应的 manager rollback/不提交路径。
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
  // manager_epoch 记录 reserve_identity 完成后 candidate 所属的 manager 代际。
  // create_* 在构造 authoritative resource 的外部调用窗口返回后必须重新核对它，
  // 防止旧 allocator reservation 与更新后的 registry publication 拼接。
  longint unsigned manager_epoch;
  int unsigned local_id;
  int unsigned prior_serial;
  bit used_free_id;
  bit registered_binding;

  // 功能：构造一个尚未授权的 identity candidate，并清空所有分配与回滚字段。
  // 输入/输出及副作用：name（输入）仅设置对象名称；构造函数初始化 kind、owner、handle、
  //   manager_epoch、local_id、prior_serial、used_free_id 和 registered_binding，不修改 manager 账本。
  // 失败/边界：默认 candidate 不是有效 reservation；必须由 resource manager 成功填充
  //   owner/handle 后才能用于创建或 rollback，外部调用方不能凭默认字段发布资源。
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

  // 功能：判断 candidate 是否包含 manager reserve_identity 成功后所需的完整 detached 证据。
  // 输入/输出及副作用：函数只读取 kind、owner、handle、local_id 和 serial 字段，返回 bit；
  //   不写入 candidate、registry 或 allocator，也不取得外部资源所有权。
  // 失败/边界：owner 或 handle 为空、kind 不是对象资源、或 handle.kind 与 kind 不一致时返回 0；
  //   Function kind 仅允许作为默认空状态，不能被当作可发布的对象 reservation。
  function bit valid();
    return owner != null && handle != null &&
           kind != RDMA_RESOURCE_FUNCTION &&
           handle.kind == kind;
  endfunction

  // 功能：清除 candidate 中的 transient reservation 证据，使 rollback 或发布完成后的对象不再
  //   被误用为第二次提交输入。
  // 输入/输出及副作用：clear 读取并清零 candidate 的全部字段，断开 owner/handle 引用；不修改
  //   resource manager 的 registry、allocator 或已发布 resource。
  // 失败/边界：clear 对默认或已清除 candidate 幂等；它不会自动回滚 manager，调用方必须先调用
  //   manager 的 rollback_identity_candidate()（如需撤销）再清除。
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

// 设计说明：Function 创建同时建立 generation binding、Function resource 和 release
// tombstone，不能复用普通对象的 serial 回滚规则；该 candidate 只携带这条专用路径的
// detached owner/binding 与 local-ID 回滚证据，避免把 Function 的 incarnation 语义隐含在
// 普通 resource candidate 的 kind 分支中。
class rdma_function_identity_candidate;
  rdma_function_handle owner;
  rdma_handle handle;
  rdma_function_binding trusted_binding;
  string owner_key;
  // manager_epoch 记录 Function generation reservation 完成后的 manager mutation epoch，
  // 供 create_function 在 binding projection 返回后拒绝过期 identity。
  longint unsigned manager_epoch;
  int unsigned local_id;
  bit used_free_id;
  bit registered_binding;

  // 功能：构造一个尚未提交 Function identity 的专用 candidate，并清空 owner、binding、
  // local-ID 与 registration 回滚证据。
  // 输入/输出及副作用：name（输入）仅设置对象名称；构造不访问 resource manager 账本，
  //   不注册 binding，也不取得外部对象所有权。
  // 失败/边界：默认 candidate 不是有效 reservation；必须由 manager 成功填充 detached
  //   owner/handle/trusted_binding 后才能构造 Function resource 或执行 rollback。
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

  // 功能：判断 Function candidate 是否包含专用 reserve_identity 路径成功所需的完整值。
  // 输入/输出及副作用：只读取 owner、handle、trusted_binding、owner_key 和 local_id，返回
  //   bit；不修改 candidate、registry 或 allocator，也不取得外部资源所有权。
  // 失败/边界：任一 detached identity/binding 缺失、owner/handle kind 不是 FUNCTION 或
  //   owner_key 为空时返回 0；部分 candidate 不得用于 publication。
  function bit valid();
    return owner != null && handle != null && trusted_binding != null &&
           owner.kind == RDMA_RESOURCE_FUNCTION &&
           handle.kind == RDMA_RESOURCE_FUNCTION &&
           owner_key != "";
  endfunction

  // 功能：清除 Function candidate 的 transient reservation 证据，使 rollback 或 publication
  //   完成后同一对象不能被误用为第二次提交输入。
  // 输入/输出及副作用：清零 owner、handle、trusted_binding、owner_key、local-ID 和标记；不
  //   修改 resource manager 的 registry、allocator、generation ledger 或已发布 resource。
  // 失败/边界：对默认或已清除 candidate 幂等；如需撤销 manager 账本，调用方必须先执行
  //   rollback_function_identity_candidate()。
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

// 设计说明：resource publication candidate 把 register_resource() 中可能触发
//   factory/clone 的 detached 投影阶段与 registry/代际账本提交阶段分开。candidate
//   只保存一次投影得到的值快照和稳定 key，不拥有 manager 的 registry、allocator、锁
//   或外部 adapter；因此外部投影返回后，commit 可以在没有第二次外部调用的窗口内完成。
class rdma_resource_publication_candidate;
  string registry_key;
  string incarnation_key;
  string generation_key;
  // manager_epoch 记录 stage 时 resource manager 的 publication/allocator 代际。
  // commit 只能接受同一代 candidate，防止 stage→commit 窗口内的并发 mutation
  // 让旧快照覆盖较新的 registry 或 allocator 状态。
  longint unsigned manager_epoch;
  rdma_resource registry_copy;
  rdma_resource published;
  rdma_function_handle owner_copy;
  rdma_handle handle_copy;

  // 功能：构造一个尚未完成 resource publication staging 的 detached candidate，清空
  //   registry/代际 key 和所有投影对象引用，供 manager 在一次 stage→commit 窗口内填充。
  // 输入/输出及副作用：name（输入）仅设置对象名称；构造不访问 registry、allocator 或
  //   外部 adapter，也不取得任何 resource 所有权。
  // 失败/边界：默认 candidate 不是可提交状态；必须由 manager 成功完成四类投影和 key
  //   计算后才能 commit，部分 candidate 不能被当作已发布 resource 使用。
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

  // 功能：valid 判断 publication candidate 是否已经同时具备 registry 快照、published
  //   快照、owner/handle identity 和与快照严格一致的三类稳定 key，供 commit 阶段拒绝半成品
  //   或被篡改的 detached candidate。
  // 输入/输出及副作用：函数只读取 candidate 字段并返回 bit，不修改 candidate、registry
  //   或任何 allocator/外部资源状态；key 比较依据与 resource manager 的 canonical 格式相同。
  // 失败/边界：任一快照或 key 为空、owner/handle kind 不匹配或 handle kind 未注册、
  //   registry/published 的 owner 或 handle identity 不一致，或三类 key 不能由同一组
  //   owner/handle 字段重算得到时返回 0；
  //   失败不能由 commit 猜测默认 owner、修补 key 或重新投影补齐。
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

  // 功能：clear 丢弃 publication stage 产生的 detached 快照和 key，使 candidate 在
  //   commit 或失败回滚后不能被重复提交。
  // 输入/输出及副作用：函数清空本对象全部字段并断开快照引用；不删除 manager registry，
  //   不回滚 allocator，也不改变已经提交的 resource。
  // 失败/边界：对默认或已清除 candidate 幂等；若需要撤销 identity reservation，调用方
  //   必须先执行 resource manager 的 rollback helper，再调用 clear。
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
