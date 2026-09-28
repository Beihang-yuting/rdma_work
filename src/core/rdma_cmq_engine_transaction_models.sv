// 目录：核心执行层 core/rdma_cmq_engine_transaction_models.sv。
// 职责：集中定义 CMQ runtime 提交、复位候选、slot 记录和 MMIO arm observer 等事务值模型，
//   让 rdma_cmq_engine 只负责状态机、账本所有权和跨组件协调。
// 依赖：依赖 rdma_model_pkg 的 CMQ 快照/提交记录、rdma_adapter_pkg 的 Host-memory 与
//   scheduler 契约，以及 rdma_doorbell_scheduler.sv 中的 observer 基类。
// 所有权与生命周期：本文件中的 UVM 对象和候选 struct 只描述事务值或 staging 图；
//   engine 仍是 runtime、journal、fence 和外部 facade 的唯一可变所有者。

// 设计说明：transaction model 与 engine 实现物理分离，但不改变任何字段布局、
//   UVM factory 注册或 observer 的非拥有引用语义。跨文件的 engine 回调通过前置类声明连接。
// 设计说明：slot 状态只描述 CMQ ring 中单个位置的可回收阶段；完整的
//   publication/recovery authority 仍由 engine 的 journal、counter 和锁共同维护。
typedef enum bit [2:0] {
  CMQ_SLOT_FREE,
  CMQ_SLOT_PUBLISHED,
  CMQ_SLOT_COMPLETED,
  CMQ_SLOT_TIMED_OUT_QUARANTINED,
  CMQ_SLOT_LATE_COMPLETED,
  CMQ_SLOT_RESET_CANCELLED
} rdma_cmq_slot_state_e;

// 功能：把完整 Function incarnation 与 engine/batch 单调身份编码为固定宽度、
//   小写十六进制的外部 journal key，避免同 route 或同 Function 的 engine 实例串线。
// 输入/输出及副作用：identity、engine_instance_id、engine_incarnation 和 batch_id
//   为只读输入；batch_key/failure_reason 入口清空，成功仅发布 batch_key。
// 失败/边界：identity 为空、runtime subtype/route/UID/generation 非法，或三个
//   engine/batch 标量任一为零时返回 0；不保留 partial key、不调用 factory。
function automatic bit rdma_cmq_format_batch_key(
  input rdma_function_identity identity,
  input longint unsigned engine_instance_id,
  input longint unsigned engine_incarnation,
  input longint unsigned batch_id,
  output string batch_key,
  output string failure_reason
);
  batch_key = "";
  failure_reason = "";
  if (identity == null ||
      identity.get_object_type() != rdma_function_identity::get_type() ||
      !rdma_cmq_identity_shape_valid(identity)) begin
    failure_reason = "CMQ batch Function identity is invalid or unsupported";
    return 1'b0;
  end
  if (engine_instance_id == 0) begin
    failure_reason = "CMQ batch engine instance ID is zero";
    return 1'b0;
  end
  if (engine_incarnation == 0) begin
    failure_reason = "CMQ batch engine incarnation is zero";
    return 1'b0;
  end
  if (batch_id == 0) begin
    failure_reason = "CMQ batch ID is zero";
    return 1'b0;
  end

  batch_key = $sformatf(
    {"root=%04h|host=%08h|kind=%01h|parent=%04h:%02h:%02h.%01h|",
     "vf=%04h|bdf=%04h:%02h:%02h.%01h|gfid=%08h|uid=%016h|",
     "gen=%08h|reset=%016h|engine=%016h|inc=%016h|batch=%016h"},
    identity.key.root_id,
    identity.key.host_topology_key,
    identity.key.function_kind,
    identity.key.parent_pf_bdf.segment,
    identity.key.parent_pf_bdf.bus,
    identity.key.parent_pf_bdf.device,
    identity.key.parent_pf_bdf.function_num,
    identity.key.vf_index,
    identity.key.bdf.segment,
    identity.key.bdf.bus,
    identity.key.bdf.device,
    identity.key.bdf.function_num,
    identity.global_function_id,
    identity.function_uid,
    identity.generation,
    identity.reset_epoch,
    engine_instance_id,
    engine_incarnation,
    batch_id
  );
  return 1'b1;
endfunction

class rdma_cmq_slot_record extends uvm_object;
  `uvm_object_utils(rdma_cmq_slot_record)

  longint unsigned slot_sequence;
  int unsigned sq_index;
  bit sq_wrap;
  rdma_cmq_slot_state_e state;
  rdma_cmq_ticket ticket;
  rdma_cmq_expected_response expected;
  bit [4:0] command_token;
  // 设计说明：runtime slot 只保存到 retained journal authority 的稳定定位值；
  //   batch_key 与压缩后的 item 下标必须成对安装，禁止从 request_index 或
  //   当前 Function/runtime 重新推断，以免 timeout/reset 跨批次回写。
  string batch_key;
  int unsigned journal_item_index;

  // 功能：构造空闲 slot record，并把 journal locator 初始化为空 key/零下标。
  // 输入/输出及副作用：name 传给 uvm_object；清零 slot/ticket/token/locator，
  //   不登记 runtime 或 retained journal 行。
  // 失败/边界：默认对象没有发布 authority；batch_key 为空时即使下标为零也
  //   不能定位 journal，不接管 Host-memory、PCIe 或 manager 生命周期。
  function new(string name = "rdma_cmq_slot_record");
    super.new(name);
    slot_sequence = 0;
    sq_index = 0;
    sq_wrap = 1'b0;
    state = CMQ_SLOT_FREE;
    ticket = null;
    expected = null;
    command_token = '0;
    batch_key = "";
    journal_item_index = 0;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_slot_record 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CMQ slot record copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_slot_record rhs_record;

    super.do_copy(rhs);
    if (!$cast(rhs_record, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ slot record copy mismatch")
    slot_sequence = rhs_record.slot_sequence;
    sq_index = rhs_record.sq_index;
    sq_wrap = rhs_record.sq_wrap;
    state = rhs_record.state;
    ticket = rdma_cmq_clone_ticket_value(rhs_record.ticket,
                                          "CMQ slot record");
    if (rhs_record.expected == null)
      expected = null;
    else begin
      uvm_object cloned_object;
      cloned_object = rhs_record.expected.clone();
      if (cloned_object == null || !$cast(expected, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE",
                   "CMQ slot expected response clone mismatch")
    end
    command_token = rhs_record.command_token;
    batch_key = rhs_record.batch_key;
    journal_item_index = rhs_record.journal_item_index;
  endfunction
endclass

// 设计说明：单项预分配发布值把 journal request index 与既有 slot/registry
//   发布键绑定；它只由 engine 锁内拥有，不形成第二份提交 authority。
class rdma_cmq_preallocated_publish_item extends uvm_object;
  `uvm_object_utils(rdma_cmq_preallocated_publish_item)

  int unsigned request_index;
  rdma_cmq_slot_record slot_record;
  string command_key;
  string entry_key;
  bit [4:0] command_token;

  // 功能：构造空的 CMQ 预分配发布单项，等待原子安装入口填入完整 slot 与键。
  // 输入/输出及副作用：name 传给 uvm_object；清零 request/token 并清空引用和文本。
  // 失败/边界：默认对象是 partial value，不能安装或发布到 runtime registry。
  function new(string name = "rdma_cmq_preallocated_publish_item");
    super.new(name);
    request_index = 0;
    slot_record = null;
    command_key = "";
    entry_key = "";
    command_token = '0;
  endfunction
endclass

// 设计说明：批次预分配发布值保存 authentic MMIO arm 原子提交所需的固定
//   sequence/profile 格式和有序单项；安装后由 arm 消费，PRE rollback、
//   journal 删除或 reset 也会回收。arm 后 journal 仍可继续保留恢复证据。
class rdma_cmq_preallocated_publish_batch extends uvm_object;
  `uvm_object_utils(rdma_cmq_preallocated_publish_batch)

  string batch_key;
  longint unsigned attempt_id;
  longint unsigned final_sequence;
  bit profile_format_valid;
  rdma_byte_endian_e profile_endian;
  int unsigned profile_hardware_version;
  rdma_cmq_preallocated_publish_item items[$];

  // 功能：构造空的 CMQ 批次预分配发布值，默认没有有效 profile 格式或单项。
  // 输入/输出及副作用：name 传给 uvm_object；清空 key/items 并将计数与格式置零。
  // 失败/边界：默认对象不能安装；必须与同批 journal record 一一匹配后才可发布。
  function new(string name = "rdma_cmq_preallocated_publish_batch");
    super.new(name);
    batch_key = "";
    attempt_id = 0;
    final_sequence = 0;
    profile_format_valid = 1'b0;
    profile_endian = RDMA_ENDIAN_LITTLE;
    profile_hardware_version = 0;
    items.delete();
  endfunction
endclass

// 设计说明：reset candidate 把每个将被隔离的 runtime slot 与其 retained
//   journal item 的稳定定位、取消 completion 一起预建；它不拥有 runtime
//   registry，commit 前不会把任何句柄写回 engine。
class rdma_cmq_reset_item_candidate extends uvm_object;
  `uvm_object_utils(rdma_cmq_reset_item_candidate)

  string batch_key;
  // journal_item_index 是压紧后的 admitted-item 位置；它必须与调用方提供的
  // request_index 分开保存，因为本地拒绝后 request_index 允许出现空洞。
  int unsigned journal_item_index;
  int unsigned request_index;
  int unsigned slot_index;
  string command_key;
  string entry_key;
  rdma_cmq_completion cancellation_completion;

  // 功能：构造一个未绑定 journal 的 reset 单项候选，清空定位键和取消结果。
  // 输入/输出及副作用：name 仅设置 UVM 名称；本构造不修改 engine ledger，也不取得外部 backing 所有权。
  // 失败/边界：默认候选没有 batch/slot authority，不能直接提交；调用方必须在 release 前完成全部字段校验。
  function new(string name = "rdma_cmq_reset_item_candidate");
    super.new(name);
    batch_key = "";
    journal_item_index = 0;
    request_index = 0;
    slot_index = 0;
    command_key = "";
    entry_key = "";
    cancellation_completion = null;
  endfunction
endclass

// 设计说明：reset batch candidate 保存一个 batch 的旧 journal 行、完整 proof
//   和 detached 返回 proof；proof 只在 backing release 成功后安装到 retained row。
class rdma_cmq_reset_batch_candidate extends uvm_object;
  `uvm_object_utils(rdma_cmq_reset_batch_candidate)

  string batch_key;
  rdma_cmq_batch_submission_record quarantined_record;
  rdma_cmq_reset_isolation_proof journal_proof;
  rdma_cmq_reset_isolation_proof returned_proof;
  rdma_cmq_submission_state_e reduced_state;

  // 功能：构造一个未提交的 reset batch 候选，初始化 proof/record 句柄和 reducer 结果。
  // 输入/输出及副作用：name 仅设置 UVM 名称；构造不插入 journal、不推进 proof counter。
  // 失败/边界：空 batch_key 或 null proof/record 只能作为 staging 中间值，不能进入 commit。
  function new(string name = "rdma_cmq_reset_batch_candidate");
    super.new(name);
    batch_key = "";
    quarantined_record = null;
    journal_proof = null;
    returned_proof = null;
    reduced_state = RDMA_CMQ_SUBMISSION_STAGED;
  endfunction
endclass

// 设计说明：reset candidate 是 release 前唯一的本地事务图，聚合旧 backing
//   authority、逐项取消结果、逐 batch proof 及 caller 输出；commit 只消费这张图。
class rdma_cmq_reset_candidate extends uvm_object;
  `uvm_object_utils(rdma_cmq_reset_candidate)

  rdma_function_identity isolated_identity;
  rdma_dma_mapping backing_release_authority;
  // 以下句柄只是 release 返回后的非拥有见证值，用于重新核对 engine runtime；
  // 上方 detached authority 才是唯一传给 release 的值，这些句柄不会进入 engine
  // 可达状态，也不延长外部资源生命周期。
  rdma_dma_mapping runtime_backing_mapping;
  rdma_host_mem_api backing_release_service;
  rdma_host_mem_api runtime_host_mem;
  bit backing_release_opaque;
  rdma_cmq_engine_state_e runtime_state;
  longint unsigned engine_incarnation;
  longint unsigned runtime_publish_seq;
  longint unsigned runtime_retire_seq;
  longint unsigned runtime_cq_consume_seq;
  longint unsigned runtime_batch_id_counter;
  longint unsigned runtime_attempt_id_counter;
  longint unsigned runtime_reset_proof_id_counter;
  int unsigned runtime_journal_count;
  int unsigned runtime_ticket_index_count;
  int unsigned runtime_preallocation_count;
  int unsigned runtime_observer_count;
  int unsigned runtime_slot_count;
  int unsigned runtime_token_count;
  int unsigned runtime_command_count;
  int unsigned runtime_entry_count;
  int unsigned runtime_terminal_fifo_count;
  int unsigned runtime_diagnostic_fifo_count;
  int unsigned runtime_late_fifo_count;
  string runtime_fenced_batch_key;
  string runtime_fence_reason;
  rdma_cmq_reset_item_candidate items[$];
  rdma_cmq_reset_batch_candidate batches[$];
  rdma_cmq_completion returned_completions[$];

  // 功能：构造空 reset candidate，准备承载旧 incarnation 的 detached staging 图。
  // 输入/输出及副作用：name 仅设置 UVM 名称；所有队列清空，不触碰 engine 或 Host-memory。
  // 失败/边界：默认 candidate 不含 release authority，不能调用 release/commit；失败 staging 必须整体丢弃。
  function new(string name = "rdma_cmq_reset_candidate");
    super.new(name);
    isolated_identity = null;
    backing_release_authority = null;
    runtime_backing_mapping = null;
    backing_release_service = null;
    runtime_host_mem = null;
    backing_release_opaque = 1'b0;
    runtime_state = RDMA_CMQ_ENGINE_UNCONFIGURED;
    engine_incarnation = 0;
    runtime_publish_seq = 0;
    runtime_retire_seq = 0;
    runtime_cq_consume_seq = 0;
    runtime_batch_id_counter = 0;
    runtime_attempt_id_counter = 0;
    runtime_reset_proof_id_counter = 0;
    runtime_journal_count = 0;
    runtime_ticket_index_count = 0;
    runtime_preallocation_count = 0;
    runtime_observer_count = 0;
    runtime_slot_count = 0;
    runtime_token_count = 0;
    runtime_command_count = 0;
    runtime_entry_count = 0;
    runtime_terminal_fifo_count = 0;
    runtime_diagnostic_fifo_count = 0;
    runtime_late_fifo_count = 0;
    runtime_fenced_batch_key = "";
    runtime_fence_reason = "";
    items.delete();
    batches.delete();
    returned_completions.delete();
  endfunction
endclass

typedef class rdma_cmq_engine;

// 设计说明：observer 是 scheduler 进入 MMIO_MAYBE_VISIBLE 前的一次性
//   capability；它仅保存 engine 非拥有句柄和冻结标量，真实 authority
//   由 engine 内 exact-object registry 与 journal 联合认证。
class rdma_cmq_mmio_arm_observer
  extends rdma_doorbell_submission_observer;
  local rdma_cmq_engine owner;
  local string capability_key;
  local string batch_key;
  local longint unsigned attempt_id;
  local longint unsigned engine_incarnation;
  local bit configured;

  // 功能：构造尚未配置的 MMIO arm observer，建立空 authority 起点。
  // 输入/输出及副作用：name 传给父类；owner/key 清空，ID 和 configured 清零。
  // 失败/边界：构造不登记 capability、不取得 engine 所有权；configure 成功前
  //   回调只能报稳定非法调用诊断。
  function new(string name = "rdma_cmq_mmio_arm_observer");
    super.new(name);
    owner = null;
    capability_key = "";
    batch_key = "";
    attempt_id = 0;
    engine_incarnation = 0;
    configured = 1'b0;
  endfunction

  // 功能：一次性冻结 observer 的 owner、capability/batch key 和 attempt/incarnation。
  // 输入/输出及副作用：五个 *_arg 为输入；首次完整配置时写入
  //   local 字段并返回 OK，owner_arg 仍由外部拥有。
  // 失败/边界：已配置返回 RESOURCE_BUSY；null owner、空 key 或零 ID
  //   返回 INVALID_ARGUMENT，两类失败均不改写任何 local 字段。
  function rdma_status configure(
    input rdma_cmq_engine owner_arg,
    input string capability_key_arg,
    input string batch_key_arg,
    input longint unsigned attempt_id_arg,
    input longint unsigned engine_incarnation_arg
  );
    if (configured)
      return rdma_cmq_direct_status(
        RDMA_SC_RESOURCE_BUSY, "CMQ MMIO arm observer is already configured"
      );
    if (owner_arg == null || capability_key_arg.len() == 0 ||
        batch_key_arg.len() == 0 || attempt_id_arg == 0 ||
        engine_incarnation_arg == 0)
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ MMIO arm observer configuration is incomplete"
      );

    owner = owner_arg;
    capability_key = capability_key_arg;
    batch_key = batch_key_arg;
    attempt_id = attempt_id_arg;
    engine_incarnation = engine_incarnation_arg;
    configured = 1'b1;
    return rdma_cmq_direct_status(RDMA_SC_OK);
  endfunction

  // 功能：查询 configure() 是否已成功冻结完整 capability 字段。
  // 输入/输出及副作用：无输入；只读并返回 configured，不修改 observer。
  // 失败/边界：初始或失败 configure 后返回 0，不根据其他字段推测。
  function bit is_configured();
    return configured;
  endfunction

  // 功能：返回 configure() 冻结的 engine 非拥有 owner 句柄供 identity 认证。
  // 输入/输出及副作用：无输入；只读 owner 并返回 exact handle。
  // 失败/边界：未配置时返回 null，不接管 engine 生命周期。
  function rdma_cmq_engine owner_handle();
    return owner;
  endfunction

  // 功能：返回冻结的 registry capability key 值供 exact-row 查找。
  // 输入/输出及副作用：无输入；只读 capability_key，不修改 registry。
  // 失败/边界：未配置时返回空字符串，字符串知识本身不授权。
  function string get_capability_key();
    return capability_key;
  endfunction

  // 功能：返回冻结的 journal batch key 值供 record 查找。
  // 输入/输出及副作用：无输入；只读 batch_key，不查询 engine 状态。
  // 失败/边界：未配置时返回空字符串，不用 key 重建 owner authority。
  function string get_batch_key();
    return batch_key;
  endfunction

  // 功能：返回冻结的 submission attempt ID 供 journal tuple 认证。
  // 输入/输出及副作用：无输入；只读 attempt_id，不推进 engine counter。
  // 失败/边界：未配置时返回零，零值不是有效 authority。
  function longint unsigned get_attempt_id();
    return attempt_id;
  endfunction

  // 功能：返回冻结的 engine incarnation 供拒绝 reset/reprepare 后旧能力。
  // 输入/输出及副作用：无输入；只读 engine_incarnation，无外部副作用。
  // 失败/边界：未配置时返回零，不回退查询 owner 当前代际。
  function longint unsigned get_engine_incarnation();
    return engine_incarnation;
  endfunction

  // 功能：在 scheduler 即将使 MMIO 可见时同步委托 owner 消费本 capability。
  // 输入/输出及副作用：无输入/返回值；配置完整时传入 this，
  //   由 owner 原子安装预分配 runtime 账本。
  // 失败/边界：未配置或 null owner 只发布稳定 UVM_ERROR 并返回，
  //   不解引用 owner；实现不得等待、分配、取锁或重入 scheduler/service。
  extern virtual function void before_mmio_maybe_visible();
endclass

// 设计说明：observed submit 只在一次持锁提交中暂存 transport 原始证据与
//   分类结果；operation_status 是本次调用独占的直接复制值，其他字段是纯标量。
//   这里不保存 journal、observer 或外部服务句柄，PRE rollback 与最终账本
//   写入仍由 engine 的 submit task 在原有提交点完成。
typedef struct {
  rdma_status operation_status;
  rdma_status_code_e observation_code;
  string observation_message;
  rdma_submission_effect_e raw_effect;
  bit rollback_pre;
  rdma_cmq_submission_state_e state;
  rdma_submission_effect_e cumulative_effect;
  rdma_submission_effect_e attempt_effect;
  bit publication_retry_safe;
} rdma_cmq_submit_transport_decision_t;

// 设计说明：逐项 candidate staging 在 submit_batch_observed 的同一锁内持有
//   两个尚未安装的候选句柄、依赖队列和格式/失败游标。struct 本身不是 UVM
//   对象或第二份 journal；候选对象仍由调用方创建，函数仅在调用期间借用。
//   函数结束后把借用候选对象中暂存的条目、dependencies 与格式交给原
//   task 的后续阶段；失败时整图随本次调用丢弃，不能留在持久账本中。
typedef struct {
  rdma_cmq_batch_submission_record record_candidate;
  rdma_cmq_preallocated_publish_batch preallocated_candidate;
  rdma_doorbell_dependency dependencies[$];
  bit staged_profile_format_valid;
  rdma_byte_endian_e staged_profile_endian;
  int unsigned staged_profile_hardware_version;
  rdma_status transaction_status;
  bit transaction_failed;
} rdma_cmq_submit_candidate_stage_t;

// 设计说明：RETRY candidate staging 只在唯一 recovery 调用内借用 descriptor、
//   dependency、observer 和 deadline 证据；它不是 journal/runtime 第二份账本。
//   helper 成功后由原 task 在同一锁内执行 expected-attempt 重验和 CAS，失败时
//   candidate 图不进入 engine registry，保留 pre-MMIO 的可回收生命周期。
typedef struct {
  rdma_doorbell_dependency dependencies[$];
  rdma_doorbell_desc doorbell_snapshot_desc;
  rdma_cmq_mmio_arm_observer observer;
  longint unsigned candidate_attempt;
  time minimum_remaining;
  string capability_key;
} rdma_cmq_recovery_candidate_stage_t;

// 设计说明：terminal-transition candidate stage 把 expiry timeout 和 generation
//   cancel 共用的逐 slot completion、journal detached 图集中保存，确保后续 slot
//   的 snapshot/reducer 失败时不会提前写入 engine ledger。它只是锁内调用期
//   context，不拥有 slot、journal 或 FIFO；两种 policy 仅由 caller 决定候选内容。
typedef struct {
  rdma_cmq_slot_record staged_records[$];
  rdma_cmq_completion staged_completions[$];
  rdma_cmq_batch_submission_record staged_batches[$];
  rdma_cmq_batch_submission_item_record staged_items[$];
  rdma_cmq_completion staged_journal_completions[$];
  rdma_cmq_submission_state_e staged_batch_states[$];
  bit staged_recovery_required[$];
  string staged_command_keys[$];
} rdma_cmq_terminal_transition_candidate_stage_t;
