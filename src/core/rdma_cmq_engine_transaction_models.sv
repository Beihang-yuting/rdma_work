// 目录：核心执行层 core/rdma_cmq_engine_transaction_models.sv。
// 职责：集中定义 CMQ runtime 提交/完成、复位候选、slot 记录和 MMIO arm observer 等事务值模型，
//   rdma_cmq_engine 只负责状态机、账本所有权和跨组件协调。
// 依赖：rdma_model_pkg 的 CMQ 快照/提交记录、rdma_adapter_pkg 的 Host-memory/scheduler 契约、
//   rdma_doorbell_scheduler.sv 中的 observer 基类。
// 所有权与生命周期：本文件的 UVM 对象和候选 struct 只描述事务值或 staging 图；
//   engine 仍是 runtime、journal、fence 和外部 facade 的唯一可变所有者。

// 设计说明：本文件与 engine 物理分离，不改变字段布局、factory 注册或 observer 的非拥有语义；
//   engine 回调经前置类声明连接。slot 状态只描述单个 ring 位置的可回收阶段，
//   publication/recovery authority 仍由 engine 的 journal、counter 和锁维护。
typedef enum bit [2:0] {
  CMQ_SLOT_FREE,
  CMQ_SLOT_PUBLISHED,
  CMQ_SLOT_COMPLETED,
  CMQ_SLOT_TIMED_OUT_QUARANTINED,
  CMQ_SLOT_LATE_COMPLETED,
  CMQ_SLOT_RESET_CANCELLED
} rdma_cmq_slot_state_e;

// 功能：把 Function incarnation 与 engine/batch 单调身份编码为定宽小写十六进制 journal key。
// 输入/输出及副作用：入参只读；batch_key/failure_reason 入口清空，成功仅发布 batch_key。
// 失败/边界：identity 为空、runtime subtype/route/UID/generation 非法或任一 engine/batch
//   标量为零时返回 0；不保留 partial key。
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
  // 设计说明：slot 只保存到 retained journal 的稳定定位值；batch_key 与压缩后的 item 下标
  //   必须成对安装，不得从 request_index 或当前 Function 推断，以免 timeout/reset 跨批次回写。
  string batch_key;
  int unsigned journal_item_index;

  // 功能：构造空闲 slot record，journal locator 置空 key/零下标。
  // 输入/输出及副作用：name 传给 uvm_object；清零 slot/ticket/token/locator。
  // 失败/边界：默认对象无发布 authority；batch_key 为空时下标零不能定位 journal。
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

  // 功能：把 rhs 的值字段复制到当前对象，得到与源隔离的快照。
  // 输入/输出及副作用：rhs 为源，只读；覆盖当前字段，嵌套句柄 clone 或保持非拥有引用。
  // 失败/边界：源为空、clone/cast 失败或类型不符时 UVM fatal（CMQ slot record copy mismatch）。
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
      expected = rdma_deep_copy#(rdma_cmq_expected_response)::of(
        rhs_record.expected, "CMQ slot expected response clone mismatch");
    end
    command_token = rhs_record.command_token;
    batch_key = rhs_record.batch_key;
    journal_item_index = rhs_record.journal_item_index;
  endfunction
endclass

// 设计说明：单项预分配发布值把 journal request index 与 slot/registry 发布键绑定；
//   仅在 engine 锁内持有，不形成第二份提交 authority。
class rdma_cmq_preallocated_publish_item extends uvm_object;
  `uvm_object_utils(rdma_cmq_preallocated_publish_item)

  int unsigned request_index;
  rdma_cmq_slot_record slot_record;
  string command_key;
  string entry_key;
  bit [4:0] command_token;

  // 功能：构造空的预分配发布单项。
  // 输入/输出及副作用：name 传给 uvm_object；清零 request/token，清空引用和文本。
  // 失败/边界：默认对象为 partial value，不能安装或发布。
  function new(string name = "rdma_cmq_preallocated_publish_item");
    super.new(name);
    request_index = 0;
    slot_record = null;
    command_key = "";
    entry_key = "";
    command_token = '0;
  endfunction
endclass

// 设计说明：批次预分配发布值保存 MMIO arm 原子提交所需的 sequence/profile 格式和有序单项；
//   安装后由 arm 消费，PRE rollback、journal 删除或 reset 也会回收；arm 后 journal 仍保留证据。
class rdma_cmq_preallocated_publish_batch extends uvm_object;
  `uvm_object_utils(rdma_cmq_preallocated_publish_batch)

  string batch_key;
  longint unsigned attempt_id;
  longint unsigned final_sequence;
  bit profile_format_valid;
  rdma_byte_endian_e profile_endian;
  int unsigned profile_hardware_version;
  rdma_cmq_preallocated_publish_item items[$];

  // 功能：构造空的批次预分配发布值，无 profile 格式或单项。
  // 输入/输出及副作用：name 传给 uvm_object；清空 key/items，计数与格式置零。
  // 失败/边界：默认对象不能安装；须与同批 journal record 一一匹配后才可发布。
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

// 设计说明：reset candidate 预建每个将被隔离的 runtime slot 与其 retained journal item 的
//   定位和取消 completion；不拥有 runtime registry，commit 前不写回 engine。
class rdma_cmq_reset_item_candidate extends uvm_object;
  `uvm_object_utils(rdma_cmq_reset_item_candidate)

  string batch_key;
  // journal_item_index 为压紧后的 admitted-item 位置，须与 request_index 分开保存
  // （本地拒绝后 request_index 可有空洞）。
  int unsigned journal_item_index;
  int unsigned request_index;
  int unsigned slot_index;
  string command_key;
  string entry_key;
  rdma_cmq_completion cancellation_completion;

  // 功能：构造未绑定 journal 的 reset 单项候选，清空定位键和取消结果。
  // 输入/输出及副作用：name 设置 UVM 名；不修改 engine ledger。
  // 失败/边界：默认候选无 batch/slot authority，release 前须完成字段校验。
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

// 设计说明：reset batch candidate 保存一个 batch 的旧 journal 行、完整 proof 与 detached
//   返回 proof；proof 仅在 backing release 成功后安装到 retained row。
class rdma_cmq_reset_batch_candidate extends uvm_object;
  `uvm_object_utils(rdma_cmq_reset_batch_candidate)

  string batch_key;
  rdma_cmq_batch_submission_record quarantined_record;
  rdma_cmq_reset_isolation_proof journal_proof;
  rdma_cmq_reset_isolation_proof returned_proof;
  rdma_cmq_submission_state_e reduced_state;

  // 功能：构造未提交的 reset batch 候选，初始化 proof/record 句柄和 reducer 结果。
  // 输入/输出及副作用：name 设置 UVM 名；不插入 journal、不推进 proof counter。
  // 失败/边界：空 batch_key 或 null proof/record 只能作 staging 中间值，不能 commit。
  function new(string name = "rdma_cmq_reset_batch_candidate");
    super.new(name);
    batch_key = "";
    quarantined_record = null;
    journal_proof = null;
    returned_proof = null;
    reduced_state = RDMA_CMQ_SUBMISSION_STAGED;
  endfunction
endclass

// 设计说明：reset candidate 是 release 前唯一的本地事务图，聚合旧 backing authority、
//   逐项取消结果、逐 batch proof 及 caller 输出；commit 只消费这张图。
class rdma_cmq_reset_candidate extends uvm_object;
  `uvm_object_utils(rdma_cmq_reset_candidate)

  rdma_function_identity isolated_identity;
  rdma_dma_mapping backing_release_authority;
  // 以下句柄是 release 返回后用于重新核对 runtime 的非拥有见证值；传给 release 的只有
  // 上方 detached authority，这些句柄不进入 engine 可达状态，也不延长外部资源生命周期。
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

  // 功能：构造空 reset candidate，承载旧 incarnation 的 detached staging 图。
  // 输入/输出及副作用：name 设置 UVM 名；队列清空，不触碰 engine 或 Host-memory。
  // 失败/边界：默认 candidate 无 release authority；失败 staging 须整体丢弃。
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

// 设计说明：observer 是 scheduler 进入 MMIO_MAYBE_VISIBLE 前的一次性 capability，仅保存
//   engine 非拥有句柄和冻结标量，真实 authority 由 engine 的 exact-object registry 与 journal 认证。
class rdma_cmq_mmio_arm_observer
  extends rdma_doorbell_submission_observer;
  local rdma_cmq_engine owner;
  local string capability_key;
  local string batch_key;
  local longint unsigned attempt_id;
  local longint unsigned engine_incarnation;
  local bit configured;

  // 功能：构造未配置的 MMIO arm observer。
  // 输入/输出及副作用：name 传给父类；owner/key 清空，ID 与 configured 清零。
  // 失败/边界：configure 成功前回调只报稳定的非法调用诊断。
  function new(string name = "rdma_cmq_mmio_arm_observer");
    super.new(name);
    owner = null;
    capability_key = "";
    batch_key = "";
    attempt_id = 0;
    engine_incarnation = 0;
    configured = 1'b0;
  endfunction

  // 功能：一次性冻结 owner、capability/batch key 和 attempt/incarnation。
  // 输入/输出及副作用：*_arg 为输入；成功写入 local 字段，owner 仍由外部拥有。
  // 失败/边界：已配置返回 RESOURCE_BUSY；null owner、空 key 或零 ID 返回 INVALID_ARGUMENT；
  //   失败均不改 local 字段。
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

  // 功能：查询 configure() 是否已成功。
  // 输入/输出及副作用：只读 configured。
  // 失败/边界：未配置或 configure 失败后返回 0。
  function bit is_configured();
    return configured;
  endfunction

  // 功能：返回冻结的 engine owner 句柄（非拥有）。
  // 输入/输出及副作用：只读。
  // 失败/边界：未配置时返回 null。
  function rdma_cmq_engine owner_handle();
    return owner;
  endfunction

  // 功能：返回冻结的 registry capability key。
  // 输入/输出及副作用：只读。
  // 失败/边界：未配置时返回空串；key 本身不授权。
  function string get_capability_key();
    return capability_key;
  endfunction

  // 功能：返回冻结的 journal batch key。
  // 输入/输出及副作用：只读。
  // 失败/边界：未配置时返回空串。
  function string get_batch_key();
    return batch_key;
  endfunction

  // 功能：返回冻结的 submission attempt ID。
  // 输入/输出及副作用：只读，不推进 engine counter。
  // 失败/边界：未配置时返回零，零非有效 authority。
  function longint unsigned get_attempt_id();
    return attempt_id;
  endfunction

  // 功能：返回冻结的 engine incarnation，用于拒绝 reset/reprepare 后的旧能力。
  // 输入/输出及副作用：只读。
  // 失败/边界：未配置时返回零，不回退查询 owner。
  function longint unsigned get_engine_incarnation();
    return engine_incarnation;
  endfunction

  // 功能：scheduler 即将使 MMIO 可见时，同步委托 owner 消费本 capability。
  // 输入/输出及副作用：配置完整时传入 this，由 owner 原子安装预分配 runtime 账本。
  // 失败/边界：未配置或 null owner 只发布稳定 UVM_ERROR 并返回；实现不得等待、分配、
  //   取锁或重入 scheduler/service。
  extern virtual function void before_mmio_maybe_visible();
endclass

// 设计说明：observed submit 只在一次持锁提交中暂存 transport 原始证据与分类结果；
//   operation_status 为本次调用独占的复制值。不保存 journal、observer 或外部句柄，
//   PRE rollback 与最终账本写入仍由 engine submit task 在原提交点完成。
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

// 设计说明：逐项 candidate staging 在 submit_batch_observed 的同一锁内持有两个未安装候选
//   句柄、依赖队列和格式/失败游标；struct 不是 UVM 对象或第二份 journal，候选由调用方创建、
//   调用期间借用，成功后交给原 task 后续阶段，失败则整图随调用丢弃。
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

// 设计说明：RETRY candidate staging 只在唯一 recovery 调用内借用 descriptor、dependency、
//   observer 和 deadline 证据；成功后由原 task 同锁内重验 expected-attempt 并 CAS，
//   失败时候选图不进入 registry，保留 pre-MMIO 可回收生命周期。
typedef struct {
  rdma_doorbell_dependency dependencies[$];
  rdma_doorbell_desc doorbell_snapshot_desc;
  rdma_cmq_mmio_arm_observer observer;
  longint unsigned candidate_attempt;
  time minimum_remaining;
  string capability_key;
} rdma_cmq_recovery_candidate_stage_t;

// 设计说明：terminal-transition candidate stage 集中保存 expiry timeout 与 generation cancel
//   共用的逐 slot completion/journal detached 图，后续 slot 的 snapshot/reducer 失败时不会
//   提前写 engine ledger；仅为锁内调用期 context，两种 policy 由 caller 决定候选内容。
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

// 设计说明：ready CQE 匹配后只把已认证的 slot 引用、命令 key、token 和 prospective retire
//   cursor 交给 engine 提交点；不拥有 slot，仅在同一次 engine_lock 内有效，不能跨 poll/reset 缓存。
typedef struct {
  rdma_cmq_slot_record record;
  string software_key;
  int unsigned token_index;
  longint unsigned retire_seq;
} rdma_cmq_polled_completion_stage_t;
