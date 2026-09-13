// 目录：核心执行层 core/rdma_cmq_engine.sv。
// 职责：管理 CMQ backing、ring/slot 账本、提交/完成/恢复状态，并在 prepare
//   生命周期安装无状态 transport facade。
// 依赖：依赖 CMQ model/profile、Host-memory adapter、doorbell scheduler、
//   rdma_cmq_transport 与共享 submission evidence。
// 所有权与生命周期：engine 拥有本地锁、快照、账本和每次 prepare 新建的
//   facade；Host-memory/profile/scheduler 是非拥有引用，backing 由 adapter 管理。

// 中文说明：rdma_cmq_engine.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

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

// 设计说明：批次预分配发布值保存 scheduler 成功后一次性提交所需的固定
//   sequence/profile 格式和有序单项；生命周期与对应 journal row 完全一致。
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
  // The journal index is the compressed, admitted-item position.  It is
  // deliberately separate from request_index, which is caller supplied and
  // may contain gaps after local rejection.
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
  // Non-owning pre-release witnesses used only to revalidate the engine after
  // the adapter call returns.  The detached authority above is the sole value
  // passed to release; these handles never become engine-reachable state.
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

class rdma_cmq_engine extends uvm_object;
  `uvm_object_utils(rdma_cmq_engine)

  localparam int unsigned CMQ_DEPTH = 32;
  localparam int unsigned CMQE_BYTES = 64;
  localparam int unsigned SQ_BYTES = 2048;
  localparam int unsigned CQ_OFFSET = SQ_BYTES;
  localparam int unsigned BACKING_BYTES = 2 * SQ_BYTES;

  protected semaphore engine_lock;
  protected rdma_cmq_engine_state_e engine_state;
  protected rdma_function_binding prepared_binding;
  protected rdma_dma_request_context dma_context;
  protected rdma_cmq cmq_snapshot;
  protected rdma_dma_mapping backing_mapping;
  protected rdma_host_mem_api host_mem;
  protected rdma_doorbell_scheduler scheduler;
  protected rdma_cmq_transport transport;
  protected rdma_cmq_hw_profile profile;
  protected longint unsigned publish_seq;
  protected longint unsigned retire_seq;
  protected longint unsigned cq_consume_seq;
  protected rdma_cmq_slot_record slots[CMQ_DEPTH];
  protected bit token_in_use[CMQ_DEPTH];
  protected bit [58:0] token_incarnation[CMQ_DEPTH];
  protected rdma_cmq_slot_record command_registry[string];
  protected rdma_cmq_slot_record entry_registry[string];
  protected rdma_cmq_completion terminal_fifo[$];
  protected rdma_cmq_diagnostic diagnostic_fifo[$];
  protected rdma_cmq_completion late_final_fifo[$];
  protected rdma_cmq_diagnostic last_poison;
  // A candidate mapping whose public authority failed validation must be
  // retried through the adapter's opaque allocation identity.  This bit is
  // retained only while the engine is POISONED with unreleased backing.
  protected bit backing_release_opaque;
  // The fixed CMQ profile API has no separate raw-CQE metadata hook.  A
  // profile therefore owns one endian/hardware-version format across its
  // SQE and CQE images.  Only a scheduler-successful batch may establish
  // this authority; staging and transport failures must leave it unchanged.
  protected bit profile_image_format_valid;
  protected rdma_byte_endian_e profile_image_endian;
  protected int unsigned profile_hardware_version;
  // journal identity counters are monotonic for the complete UVM-object
  // lifetime.  The four tables and fence are protected by engine_lock and
  // deliberately survive reset/reprepare while a retained row exists.
  protected longint unsigned engine_instance_id;
  protected longint unsigned engine_incarnation;
  protected longint unsigned batch_id_counter;
  protected longint unsigned attempt_id_counter;
  protected longint unsigned reset_proof_id_counter;
  protected rdma_cmq_batch_submission_record submission_journal[string];
  protected string journal_batch_by_ticket[string];
  protected rdma_cmq_preallocated_publish_batch
    preallocated_publish_batches[string];
  // 预分配 observer 行仅以 exact object identity 授权；字符串字段只是
  //   查找键，成功 arm 与对应 preallocation 在同一无分配函数中消费。
  protected rdma_cmq_mmio_arm_observer arm_observers[string];
  // Approved non-owning seam: each row retains the exact profile service
  // used to type/canonicalize only its own record.
  protected rdma_cmq_hw_profile journal_profile_by_batch[string];
  protected string fenced_batch_key;
  protected string submission_fence_reason;

  // 功能：构造 UNCONFIGURED 的 CMQ engine，冻结 UVM instance ID，并初始化
  //   单调 journal identities、四张 retained 表、fence 与短生命周期运行账本。
  // 输入/输出及副作用：name 传给 uvm_object；engine_instance_id 在 super.new 后
  //   只捕获一次；本对象拥有 engine_lock/表，外部 adapter/profile 引用均置 null。
  // 失败/边界：构造不申请 Host-memory、不创建 facade 或配置 scheduler；instance ID
  //   后续不复位，若其为零则 batch allocator fail-closed，prepare 前业务入口拒绝。
  function new(string name = "rdma_cmq_engine");
    int unsigned captured_instance_id;

    super.new(name);
    captured_instance_id = get_inst_id();
    engine_instance_id = captured_instance_id;
    engine_lock = new(1);
    engine_state = RDMA_CMQ_ENGINE_UNCONFIGURED;
    prepared_binding = null;
    dma_context = null;
    cmq_snapshot = null;
    backing_mapping = null;
    host_mem = null;
    scheduler = null;
    transport = null;
    profile = null;
    publish_seq = 0;
    retire_seq = 0;
    cq_consume_seq = 0;
    profile_image_format_valid = 1'b0;
    profile_image_endian = RDMA_ENDIAN_LITTLE;
    profile_hardware_version = 0;
    engine_incarnation = 0;
    batch_id_counter = 0;
    attempt_id_counter = 0;
    reset_proof_id_counter = 0;
    submission_journal.delete();
    journal_batch_by_ticket.delete();
    preallocated_publish_batches.delete();
    arm_observers.delete();
    journal_profile_by_batch.delete();
    fenced_batch_key = "";
    submission_fence_reason = "";
    last_poison = null;
    backing_release_opaque = 1'b0;
    foreach (slots[i]) begin
      slots[i] = null;
      token_in_use[i] = 1'b0;
      token_incarnation[i] = '0;
    end
  endfunction

  // 功能：在 rdma_cmq_engine 中，invalid_argument 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_argument 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_argument 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：在 rdma_cmq_engine 中，invalid_state 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_state 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_state 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：poison_status 校验 message 与当前对象状态的一致性，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：message（输入）；poison_status 可能更新本对象明确拥有的状态；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：poison_status 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status poison_status(string message);
    late_final_fifo.delete();
    engine_state = RDMA_CMQ_ENGINE_POISONED;
    return invalid_state(message);
  endfunction

  // 功能：在 rdma_cmq_engine 中，ring_used 只读查询当前运行时/测试账本，返回槽位、对象或恢复记录的快照而不推进事务。
  // 输入/输出及副作用：used（输出）；ring_used 读取 used 并使用字段 used，并写入 used；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：ring_used 返回 函数体规定的失败状态；具体拒绝条件包括 “CMQ publish counter precedes retire counter”；“CMQ ring occupancy exceeds depth”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status ring_used(output longint unsigned used);
    used = 0;
    if (publish_seq < retire_seq)
      return poison_status("CMQ publish counter precedes retire counter");
    used = publish_seq - retire_seq;
    if (used > CMQ_DEPTH)
      return poison_status("CMQ ring occupancy exceeds depth");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_cmq_engine 中，decoded_status_contract 从硬件 image/缓冲区解码字段，验证长度、布局和完整性后返回模型或状态。
  // 输入/输出及副作用：decoded（输入）；输入 image/bytes 只读；成功时通过返回值或 output 发布 detached 解码快照，不接管调用方缓冲区。
  // 失败/边界：decoded_status_contract 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_status decoded_status_contract(
    rdma_cmq_decoded_cqe decoded
  );
    rdma_status command_status;

    if (decoded == null || decoded.command_status == null)
      return invalid_state("CMQ decoded completion status is missing");
    command_status = decoded.command_status;
    if (command_status.category !=
        rdma_status::category_for(command_status.code))
      return invalid_state(
        "CMQ decoded completion status category is inconsistent"
      );
    if (decoded.hardware_ecode == 0) begin
      if (!command_status.ok() || command_status.hardware_code_valid ||
          command_status.hardware_code != 0 ||
          command_status.severity != RDMA_SEVERITY_INFO)
        return invalid_state(
          "CMQ successful hardware ecode status is inconsistent"
        );
    end
    else begin
      if (command_status.ok() || !command_status.hardware_code_valid ||
          command_status.hardware_code != decoded.hardware_ecode ||
          !(command_status.severity inside {
            RDMA_SEVERITY_WARNING,
            RDMA_SEVERITY_ERROR,
            RDMA_SEVERITY_FATAL
          }))
        return invalid_state(
          "CMQ failed hardware ecode status is inconsistent"
        );
    end
    return rdma_status::success();
  endfunction

  // 功能：审计 CMQ runtime 的 ring/slot/entry/command/token 粗粒度账本；
  //   token authority 覆盖 PUBLISHED 与 TIMED_OUT_QUARANTINED，但 command
  //   registry 只覆盖仍可正常完成的 PUBLISHED slot。
  // 输入/输出及副作用：used 输出 publish_seq-retire_seq；函数只读
  //   slot state、entry/command 表和 token bitmap，异常时可通过 poison_status
  //   清理 late FIFO 并把 engine 置为 POISONED。
  // 失败/边界：counter 逆序/超深度、slot/entry 与 used 不等、
  //   command 数不等于 PUBLISHED 数，或 token 数不等于
  //   PUBLISHED+TIMED_OUT_QUARANTINED 数时 fail closed；空 ring 本身合法。
  protected function rdma_status poll_ledger_status(
    output longint unsigned used
  );
    rdma_status status;
    int unsigned slot_count;
    int unsigned published_slot_count;
    int unsigned quarantined_slot_count;
    int unsigned token_count;

    used = 0;
    status = ring_used(used);
    if (!status.ok())
      return status;
    if (cq_consume_seq < retire_seq || cq_consume_seq > publish_seq)
      return poison_status("CMQ completion counters are inconsistent");
    slot_count = 0;
    published_slot_count = 0;
    quarantined_slot_count = 0;
    token_count = 0;
    foreach (slots[i]) begin
      if (slots[i] != null) begin
        slot_count++;
        if (slots[i].state == CMQ_SLOT_PUBLISHED)
          published_slot_count++;
        else if (slots[i].state inside {
                   CMQ_SLOT_TIMED_OUT_QUARANTINED,
                   CMQ_SLOT_RESET_CANCELLED
                 })
          quarantined_slot_count++;
      end
      if (token_in_use[i])
        token_count++;
    end
    if (slot_count != used || entry_registry.num() != used ||
        command_registry.num() != published_slot_count ||
        token_count != published_slot_count + quarantined_slot_count)
      return poison_status("CMQ polling ledger is inconsistent");
    return rdma_status::success();
  endfunction

  // 功能：ticket_trust_status 校验 ticket 与当前对象状态的一致性，并显式处理“CMQ ticket trust authority is incomplete”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：ticket（输入）；ticket_trust_status 读取 ticket 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：ticket_trust_status 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“CMQ ticket trust authority is incomplete”“CMQ ticket identity contains unknown bits”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status ticket_trust_status(
    rdma_cmq_ticket ticket
  );
    rdma_status status;

    if (ticket == null || ticket.function_h == null ||
        ticket.cmq_h == null || ticket.opcode_key == null)
      return invalid_argument("CMQ ticket trust authority is incomplete");
    if ($isunknown(ticket.command_id) ||
        $isunknown(ticket.slot_sequence) ||
        $isunknown(ticket.sq_index) ||
        $isunknown(ticket.sq_wrap) ||
        $isunknown(ticket.absolute_deadline) ||
        $isunknown(ticket.function_h.kind) ||
        $isunknown(ticket.function_h.function_uid) ||
        $isunknown(ticket.function_h.object_id) ||
        $isunknown(ticket.function_h.generation) ||
        $isunknown(ticket.cmq_h.kind) ||
        $isunknown(ticket.cmq_h.function_uid) ||
        $isunknown(ticket.cmq_h.object_id) ||
        $isunknown(ticket.cmq_h.generation) ||
        $isunknown(ticket.opcode_key.opcode))
      return invalid_argument("CMQ ticket identity contains unknown bits");
    status = ticket.validate();
    if (status == null)
      return invalid_argument("CMQ ticket validation returned null");
    return status;
  endfunction

  // 功能：在 rdma_cmq_engine 中，command_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：ticket（输入）；command_key 读取 ticket 并使用字段 function_uid、object_id、generation；函数返回 string，不取得调用方资源所有权。
// 失败/边界：command_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function string command_key(rdma_cmq_ticket ticket);
    return $sformatf(
      "%016h:%08h:%08h:%016h",
      ticket.function_h.function_uid,
      ticket.function_h.object_id,
      ticket.function_h.generation,
      ticket.command_id
    );
  endfunction

  // 功能：在 rdma_cmq_engine 中，entry_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：index（输入）、wrap（输入）；entry_key 读取 index、wrap 并使用字段 prepared_binding.function_uid、prepared_binding.generation；函数返回 string，不取得调用方资源所有权。
// 失败/边界：entry_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function string entry_key(int unsigned index, bit wrap);
    return $sformatf(
      "%016h:%08h:%0d:%0b",
      prepared_binding.function_uid,
      prepared_binding.generation,
      index,
      wrap
    );
  endfunction

  // 功能：make_raw_cqe_image 根据 data、raw_cqe 生成或检查硬件镜像字段，保持布局、端序和保留位约束一致。
  // 输入/输出及副作用：data（输入）、raw_cqe（输出）；make_raw_cqe_image 读取 data、raw_cqe 并使用字段 raw_cqe、raw_cqe.length、raw_cqe.alignment、raw_cqe.endian、raw_cqe.image_kind、raw_cqe.hardware_version、raw_cqe.function_generation、raw_cqe.write_target_kind，并写入 raw_cqe；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：make_raw_cqe_image 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“CMQ host read did not return one full CQE”“CMQ CQE Function authority is missing”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status make_raw_cqe_image(
    byte data[],
    output rdma_hw_image raw_cqe
  );
    raw_cqe = null;
    if (data.size() != CMQE_BYTES)
      return invalid_state("CMQ host read did not return one full CQE");
    if (prepared_binding == null)
      return invalid_state("CMQ CQE Function authority is missing");
    if (!profile_image_format_valid ||
        !(profile_image_endian inside {
          RDMA_ENDIAN_LITTLE, RDMA_ENDIAN_BIG
        }) || profile_hardware_version == 0)
      return invalid_state(
        "CMQ profile-wide CQE format authority is missing"
      );
    raw_cqe = rdma_hw_image::type_id::create("cmq_raw_cqe");
    if (raw_cqe == null)
      return invalid_state("CMQ raw CQE construction failed");
    foreach (data[i])
      raw_cqe.bytes.push_back(data[i]);
    raw_cqe.length = CMQE_BYTES;
    raw_cqe.alignment = CMQE_BYTES;
    raw_cqe.endian = profile_image_endian;
    raw_cqe.image_kind = RDMA_IMAGE_CMQ_CQE;
    raw_cqe.hardware_version = profile_hardware_version;
    raw_cqe.function_generation = prepared_binding.generation;
    raw_cqe.write_target_kind = RDMA_HW_TARGET_NONE;
    raw_cqe.backing_target = '0;
    raw_cqe.hmc_target = '0;
    raw_cqe.bar_target = '0;
    return rdma_status::success();
  endfunction

  // 功能：make_polled_completion 创建独立的 rdma_status；根据 record、raw_cqe、decoded、completion 设置字段 completion、snapshot_status、completion.ticket、completion.status、completion.raw_cqe、completion.decoded_response、status.source_engine、status.function_uid、status.generation、status.resource_id，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：record（输入）、raw_cqe（输入）、decoded（输入）、completion（输出）；make_polled_completion 读取 record、raw_cqe、decoded、completion 并使用字段 completion、snapshot_status、completion.ticket、completion.status、completion.raw_cqe、completion.decoded_response、status.source_engine、status.function_uid，并写入 completion；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：make_polled_completion 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“CMQ completion ticket authority is missing”“CMQ completion decode authority is missing”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status make_polled_completion(
    rdma_cmq_slot_record record,
    rdma_hw_image raw_cqe,
    rdma_cmq_decoded_cqe decoded,
    output rdma_cmq_completion completion
  );
    rdma_status validation_status;
    rdma_status snapshot_status;
    rdma_cmq_ticket ticket_snapshot;
    uvm_object payload_snapshot;

    completion = null;
    if (record == null || record.ticket == null ||
        record.ticket.function_h == null || record.ticket.cmq_h == null)
      return invalid_state("CMQ completion ticket authority is missing");
    if (raw_cqe == null || decoded == null ||
        decoded.command_status == null)
      return invalid_state("CMQ completion decode authority is missing");
    completion = rdma_cmq_completion::type_id::create(
      "cmq_polled_completion"
    );
    if (completion == null)
      return invalid_state("CMQ completion construction failed");
    snapshot_status = checked_completion_ticket_snapshot(
      record.ticket, ticket_snapshot
    );
    if (snapshot_status == null || !snapshot_status.ok()) begin
      completion = null;
      return (snapshot_status == null) ?
        invalid_state("CMQ completion ticket snapshot returned null") :
        snapshot_status;
    end
    completion.ticket = ticket_snapshot;
    completion.status = rdma_cmq_clone_status_value(
      decoded.command_status
    );
    completion.raw_cqe = raw_cqe;
    snapshot_status = checked_completion_payload_snapshot(
      decoded.response_payload, payload_snapshot
    );
    if (snapshot_status == null || !snapshot_status.ok()) begin
      completion = null;
      return (snapshot_status == null) ?
        invalid_state("CMQ completion payload snapshot returned null") :
        snapshot_status;
    end
    completion.decoded_response = payload_snapshot;
    if (completion.ticket == null || completion.status == null ||
        completion.raw_cqe == null) begin
      completion = null;
      return invalid_state("CMQ completion snapshot construction failed");
    end
    completion.status.source_engine = RDMA_ENGINE_CMQ;
    completion.status.function_uid =
      completion.ticket.function_h.function_uid;
    completion.status.generation =
      completion.ticket.function_h.generation;
    completion.status.resource_id = completion.ticket.cmq_h.object_id;
    completion.status.command_id = completion.ticket.command_id;
    validation_status = completion.validate();
    if (validation_status == null || !validation_status.ok()) begin
      completion = null;
      return invalid_state("CMQ completion snapshot validation failed");
    end
    return rdma_status::success();
  endfunction

  // 功能：make_timeout_status 校验 ticket、message、timeout_status 与当前对象状态的一致性，并显式处理“CMQ timeout status ticket authority is missing”；“CMQ timeout status construction failed”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：ticket（输入）、message（输入）、timeout_status（输出）；make_timeout_status 读取 ticket、message、timeout_status 并使用字段 timeout_status、timeout_status.source_engine、timeout_status.function_uid、timeout_status.generation、timeout_status.resource_id、timeout_status.command_id，并写入 timeout_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：make_timeout_status 返回 RDMA_SC_TIMEOUT；具体拒绝条件包括 “CMQ timeout status ticket authority is missing”；“CMQ timeout status construction failed”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status make_timeout_status(
    rdma_cmq_ticket ticket,
    string message,
    output rdma_status timeout_status
  );
    timeout_status = null;
    if (ticket == null || ticket.function_h == null || ticket.cmq_h == null)
      return invalid_state("CMQ timeout status ticket authority is missing");
    timeout_status = rdma_status::make(RDMA_SC_TIMEOUT, message);
    if (timeout_status == null)
      return invalid_state("CMQ timeout status construction failed");
    timeout_status.source_engine = RDMA_ENGINE_CMQ;
    timeout_status.function_uid = ticket.function_h.function_uid;
    timeout_status.generation = ticket.function_h.generation;
    timeout_status.resource_id = ticket.cmq_h.object_id;
    timeout_status.command_id = ticket.command_id;
    return rdma_status::success();
  endfunction

  // 功能：make_timeout_completion 创建独立的 rdma_status；根据 record、completion 设置字段 completion、status、completion.ticket、completion.raw_cqe、completion.decoded_response，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：record（输入）、completion（输出）；make_timeout_completion 读取 record、completion 并使用字段 completion、status、completion.ticket、completion.raw_cqe、completion.decoded_response，并写入 completion；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：make_timeout_completion 返回 函数体规定的失败状态；具体拒绝条件包括 “CMQ timeout completion authority is missing”；“CMQ timeout completion construction failed”；“CMQ timeout ticket snapshot returned null status”；“CMQ timeout status helper returned null”；“CMQ timeout completion validation failed”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status make_timeout_completion(
    rdma_cmq_slot_record record,
    output rdma_cmq_completion completion
  );
    rdma_status status;
    rdma_cmq_ticket ticket_snapshot;

    completion = null;
    if (record == null || record.ticket == null)
      return invalid_state("CMQ timeout completion authority is missing");
    completion = rdma_cmq_completion::type_id::create(
      "cmq_timeout_completion"
    );
    if (completion == null)
      return invalid_state("CMQ timeout completion construction failed");
    status = checked_completion_ticket_snapshot(record.ticket,
                                                ticket_snapshot);
    if (status == null || !status.ok()) begin
      completion = null;
      return (status == null) ?
        invalid_state("CMQ timeout ticket snapshot returned null status") :
        status;
    end
    completion.ticket = ticket_snapshot;
    status = make_timeout_status(
      completion.ticket, "CMQ command deadline expired", completion.status
    );
    if (status == null || !status.ok()) begin
      completion = null;
      return (status == null) ?
        invalid_state("CMQ timeout status helper returned null") : status;
    end
    completion.raw_cqe = null;
    completion.decoded_response = null;
    status = completion.validate();
    if (status == null || !status.ok()) begin
      completion = null;
      return invalid_state("CMQ timeout completion validation failed");
    end
    return rdma_status::success();
  endfunction

  // 功能：make_cancel_completion 创建独立的 rdma_status；根据 record、completion 设置字段 completion、status、completion.ticket、completion.status、status.source_engine、status.function_uid、status.generation、status.resource_id、status.command_id、completion.raw_cqe，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：record（输入）、completion（输出）；make_cancel_completion 读取 record、completion 并使用字段 completion、status、completion.ticket、completion.status、status.source_engine、status.function_uid、status.generation、status.resource_id，并写入 completion；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：make_cancel_completion 返回 RDMA_SC_RESET_CANCELLED、RDMA_SC_INVALID_STATE；典型拒绝条件为“CMQ cancel completion authority is missing”“CMQ cancel completion construction failed”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status make_cancel_completion(
    rdma_cmq_slot_record record,
    output rdma_cmq_completion completion
  );
    rdma_status status;
    rdma_cmq_ticket ticket_snapshot;

    completion = null;
    if (record == null || record.ticket == null ||
        record.ticket.function_h == null || record.ticket.cmq_h == null)
      return invalid_state("CMQ cancel completion authority is missing");
    completion = rdma_cmq_completion::type_id::create(
      "cmq_cancel_completion"
    );
    if (completion == null)
      return invalid_state("CMQ cancel completion construction failed");
    status = checked_completion_ticket_snapshot(record.ticket,
                                                ticket_snapshot);
    if (status == null || !status.ok()) begin
      completion = null;
      return (status == null) ?
        invalid_state("CMQ cancel ticket snapshot returned null") : status;
    end
    completion.ticket = ticket_snapshot;
    completion.status = rdma_status::make(
      RDMA_SC_RESET_CANCELLED,
      "CMQ command cancelled by generation reset"
    );
    if (completion.status == null) begin
      completion = null;
      return invalid_state("CMQ cancel status construction failed");
    end
    completion.status.source_engine = RDMA_ENGINE_RESET;
    completion.status.function_uid = ticket_snapshot.function_h.function_uid;
    completion.status.generation = ticket_snapshot.function_h.generation;
    completion.status.resource_id = ticket_snapshot.cmq_h.object_id;
    completion.status.command_id = ticket_snapshot.command_id;
    completion.raw_cqe = null;
    completion.decoded_response = null;
    status = completion.validate();
    if (status == null || !status.ok()) begin
      completion = null;
      return invalid_state("CMQ cancel completion validation failed");
    end
    return rdma_status::success();
  endfunction

  // 功能：terminal_index 使用 ticket 在对应表、队列或账本中查找唯一条目，并返回下标、对象或查找状态。
  // 输入/输出及副作用：ticket（输入）；terminal_index 读取 ticket 并使用字段 terminal_fifo；函数返回 int，不取得调用方资源所有权。
  // 失败/边界：terminal_index 查找未命中时返回 -1；该路径不隐式重试，也不转移未声明资源。
  protected function int terminal_index(rdma_cmq_ticket ticket);
    if (ticket == null)
      return -1;
    foreach (terminal_fifo[i]) begin
      if (terminal_fifo[i] != null && terminal_fifo[i].ticket != null &&
          same_ticket_value(terminal_fifo[i].ticket, ticket))
        return i;
    end
    return -1;
  endfunction

  // 功能：late_diagnostic_index 使用 ticket 在对应表、队列或账本中查找唯一条目，并返回下标、对象或查找状态。
  // 输入/输出及副作用：ticket（输入）；late_diagnostic_index 读取 ticket 并使用字段 diagnostic_fifo、kind；函数返回 int，不取得调用方资源所有权。
  // 失败/边界：late_diagnostic_index 查找未命中时返回 -1；该路径不隐式重试，也不转移未声明资源。
  protected function int late_diagnostic_index(rdma_cmq_ticket ticket);
    if (ticket == null)
      return -1;
    foreach (diagnostic_fifo[i]) begin
      if (diagnostic_fifo[i] != null &&
          diagnostic_fifo[i].kind == RDMA_CMQ_DIAG_LATE_COMPLETION &&
          diagnostic_fifo[i].ticket != null &&
          same_ticket_value(diagnostic_fifo[i].ticket, ticket))
        return i;
    end
    return -1;
  endfunction

  // 功能：late_final_index 使用 ticket 在对应表、队列或账本中查找唯一条目，并返回下标、对象或查找状态。
  // 输入/输出及副作用：ticket（输入）；late_final_index 读取 ticket 并使用字段 late_final_fifo；函数返回 int，不取得调用方资源所有权。
  // 失败/边界：late_final_index 查找未命中时返回 -1；该路径不隐式重试，也不转移未声明资源。
  protected function int late_final_index(rdma_cmq_ticket ticket);
    if (ticket == null)
      return -1;
    foreach (late_final_fifo[i]) begin
      if (late_final_fifo[i] != null &&
          late_final_fifo[i].ticket != null &&
          same_ticket_value(late_final_fifo[i].ticket, ticket))
        return i;
    end
    return -1;
  endfunction

  // 功能：ticket_has_engine_authority 比较 ticket 与当前 authority/状态字段，返回布尔结果供上层执行精确分支。
  // 输入/输出及副作用：ticket（输入）；ticket_has_engine_authority 读取 ticket 并使用字段 prepared_binding、cmq_snapshot、cmq_snapshot.handle、kind、function_uid、prepared_binding.function_uid、object_id、prepared_binding.global_function_id；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：ticket_has_engine_authority 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function bit ticket_has_engine_authority(
    rdma_cmq_ticket ticket
  );
    if (ticket == null || ticket.function_h == null || ticket.cmq_h == null ||
        prepared_binding == null || cmq_snapshot == null ||
        cmq_snapshot.handle == null)
      return 1'b0;
    if (ticket.function_h.kind != RDMA_RESOURCE_FUNCTION ||
        ticket.function_h.function_uid != prepared_binding.function_uid ||
        ticket.function_h.object_id != prepared_binding.global_function_id ||
        ticket.function_h.generation != prepared_binding.generation ||
        !ticket.cmq_h.same_instance(cmq_snapshot.handle))
      return 1'b0;
    if (terminal_index(ticket) >= 0 || late_diagnostic_index(ticket) >= 0 ||
        late_final_index(ticket) >= 0 || ticket_is_outstanding(ticket))
      return 1'b1;
    foreach (slots[i]) begin
      if (slots[i] != null && slots[i].ticket != null &&
          same_ticket_value(slots[i].ticket, ticket))
        return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：判断 ticket_is_outstanding 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：ticket（输入）；ticket_is_outstanding 读取 ticket 并使用字段 software_key；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：ticket_is_outstanding 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected function bit ticket_is_outstanding(rdma_cmq_ticket ticket);
    string software_key;

    if (ticket == null)
      return 1'b0;
    software_key = command_key(ticket);
    return command_registry.exists(software_key) &&
           command_registry[software_key] != null &&
           command_registry[software_key].ticket != null &&
           same_ticket_value(command_registry[software_key].ticket, ticket);
  endfunction

  // 设计说明：reconcile/wait 的恢复 authority 来自 retained journal，而不是
  //   当前 command/entry registry。该 helper 把稳定 ticket index 与完整 ticket
  //   值比较集中到一个锁内入口，避免旧 incarnation 在 reprepare 后被误判未知。
  // 功能：按 journal_batch_by_ticket 的稳定 key 定位唯一 retained batch/item，
  //   并验证 caller ticket 与 journal ticket 的全部公开字段相等。
  // 输入/输出及副作用：ticket 为只读 caller 输入；batch_record/journal_item 为
  //   engine-owned 非拥有输出，journal_item_index 输出命中的压缩下标；只读
  //   journal/index/profile，不执行 I/O、分配或生命周期迁移。
  // 失败/边界：ticket 为空/shape 非法、全局 index 孤立、目标 row 损坏、完整值无
  //   匹配或多重匹配分别返回 INVALID_ARGUMENT/INVALID_STATE；所有输出保持 null/0。
  protected function rdma_status locate_journal_item_by_ticket_locked(
    input rdma_cmq_ticket ticket,
    output rdma_cmq_batch_submission_record batch_record,
    output rdma_cmq_batch_submission_item_record journal_item,
    output int unsigned journal_item_index
  );
    string ticket_key;
    string batch_key;
    rdma_status status;
    int unsigned match_count;

    batch_record = null;
    journal_item = null;
    journal_item_index = 0;
    if (!rdma_cmq_ticket_shape_valid(ticket))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal ticket locator received an invalid ticket"
      );
    ticket_key = command_key(ticket);
    if (ticket_key.len() == 0)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT, "CMQ journal ticket key is empty"
      );
    status = journal_ticket_index_targets_locked();
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket locator index check returned null status"
      );
    if (!status.ok())
      return journal_status(RDMA_SC_INVALID_STATE, status.message);
    if (!journal_batch_by_ticket.exists(ticket_key))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal ticket is not installed"
      );
    batch_key = journal_batch_by_ticket[ticket_key];
    if (batch_key.len() == 0 || !submission_journal.exists(batch_key))
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket index target is missing"
      );
    status = submission_journal_invariant_locked(batch_key);
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket locator invariant returned null status"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    batch_record = submission_journal[batch_key];
    if (batch_record == null || batch_record.batch_key != batch_key)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket locator batch row is inconsistent"
      );
    match_count = 0;
    foreach (batch_record.items[i]) begin
      if (batch_record.items[i] != null &&
          same_ticket_value(batch_record.items[i].ticket, ticket)) begin
        match_count++;
        journal_item = batch_record.items[i];
        journal_item_index = i;
      end
    end
    if (match_count == 0) begin
      batch_record = null;
      journal_item = null;
      journal_item_index = 0;
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal ticket key matched but full ticket value differs"
      );
    end
    if (match_count != 1) begin
      batch_record = null;
      journal_item = null;
      journal_item_index = 0;
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket resolves to multiple retained items"
      );
    end
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：从 retained item 的 completion authority 生成一次全新 detached completion
  //   snapshot，供 wait/reconcile 在 FIFO 已消费或 engine 已 reprepare 后继续读取。
  // 输入/输出及副作用：batch_record/journal_item 为锁内只读 retained 输入，
  //   completion 为 caller-owned 输出；使用该 batch 保存的 exact profile，绝不
  //   借用当前 profile 或转移 journal completion 句柄。
  // 失败/边界：batch/item/completion/profile 缺失、生命周期 phase 不含 completion、
  //   profile snapshot seam 或 ticket/status alias 校验失败时返回非 OK 且输出 null。
  protected function rdma_status snapshot_retained_completion_locked(
    input rdma_cmq_batch_submission_record batch_record,
    input rdma_cmq_batch_submission_item_record journal_item,
    output rdma_cmq_completion completion
  );
    rdma_cmq_nonfatal_snapshot_context snapshot_context;
    rdma_cmq_hw_profile retained_profile;
    rdma_status status;

    completion = null;
    if (batch_record == null || journal_item == null ||
        journal_item.completion == null || journal_item.completion.ticket == null ||
        journal_item.completion.status == null ||
        !journal_profile_by_batch.exists(batch_record.batch_key) ||
        journal_profile_by_batch[batch_record.batch_key] == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ retained completion authority is incomplete"
      );
    retained_profile = journal_profile_by_batch[batch_record.batch_key];
    snapshot_context = new();
    status = snapshot_completion_with_profile_locked(
      journal_item.completion, snapshot_context, retained_profile,
      completion
    );
    if (status == null || !status.ok() || completion == null)
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ retained completion snapshot returned null status"
      ) : journal_status(status.code, status.message);
    if (completion.ticket == null || completion.status == null ||
        !same_ticket_value(completion.ticket, journal_item.ticket)) begin
      completion = null;
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ retained completion snapshot ticket is inconsistent"
      );
    end
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：把 retained item 的 operation status 复制成 caller-owned direct status，
  //   不触碰 completion/FIFO，也不让 caller 修改 journal status 节点。
  // 输入/输出及副作用：journal_item 为锁内只读输入，status 为新建输出；只复制
  //   status 的公开字段，不访问当前 runtime 或外部 adapter。
  // 失败/边界：item/status shape 非法时返回 INVALID_STATE/null；成功结果与 retained
  //   status 值相等但不共享对象 identity。
  protected function rdma_status snapshot_retained_operation_status_locked(
    input rdma_cmq_batch_submission_item_record journal_item,
    output rdma_status status
  );
    status = null;
    if (journal_item == null ||
        !rdma_cmq_status_shape_valid(journal_item.status))
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ retained operation status is null or malformed"
      );
    status = copy_submit_status_direct(
      journal_item.status, "cmq_reconcile_operation_status"
    );
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ retained operation status snapshot returned null"
      );
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：make_late_diagnostic 创建独立的 rdma_status；根据 record、raw_cqe、diagnostic 设置字段 diagnostic、status、diagnostic.kind、diagnostic.ticket、diagnostic.raw_cqe，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：record（输入）、raw_cqe（输入）、diagnostic（输出）；make_late_diagnostic 读取 record、raw_cqe、diagnostic 并使用字段 diagnostic、status、diagnostic.kind、diagnostic.ticket、diagnostic.raw_cqe，并写入 diagnostic；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：make_late_diagnostic 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“CMQ late diagnostic authority is missing”“CMQ late diagnostic construction failed”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status make_late_diagnostic(
    rdma_cmq_slot_record record,
    rdma_hw_image raw_cqe,
    output rdma_cmq_diagnostic diagnostic
  );
    rdma_status status;
    rdma_cmq_ticket ticket_snapshot;

    diagnostic = null;
    if (record == null || record.ticket == null || raw_cqe == null)
      return invalid_state("CMQ late diagnostic authority is missing");
    diagnostic = rdma_cmq_diagnostic::type_id::create(
      "cmq_late_completion_diagnostic"
    );
    if (diagnostic == null)
      return invalid_state("CMQ late diagnostic construction failed");
    status = checked_completion_ticket_snapshot(record.ticket,
                                                ticket_snapshot);
    if (status == null || !status.ok()) begin
      diagnostic = null;
      return (status == null) ?
        invalid_state("CMQ late diagnostic ticket snapshot returned null") :
        status;
    end
    diagnostic.kind = RDMA_CMQ_DIAG_LATE_COMPLETION;
    diagnostic.ticket = ticket_snapshot;
    status = make_timeout_status(
      diagnostic.ticket, "CMQ completion arrived after timeout",
      diagnostic.status
    );
    if (status == null || !status.ok()) begin
      diagnostic = null;
      return (status == null) ?
        invalid_state("CMQ late diagnostic status helper returned null") :
        status;
    end
    diagnostic.raw_cqe = raw_cqe;
    status = diagnostic.validate();
    if (status == null || !status.ok()) begin
      diagnostic = null;
      return invalid_state("CMQ late diagnostic validation failed");
    end
    return rdma_status::success();
  endfunction

  // 功能：make_diagnostic 创建独立的 rdma_status；根据 kind、trusted_ticket、failure、raw_cqe、diagnostic 设置字段 diagnostic、ticket_snapshot、function_snapshot、function_snapshot.kind、function_snapshot.function_uid、function_snapshot.object_id、function_snapshot.generation、cmq_snapshot_value、cmq_snapshot_value.kind、cmq_snapshot_value.function_uid，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：kind（输入）、trusted_ticket（输入）、failure（输入）、raw_cqe（输入）、diagnostic（输出）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：make_diagnostic 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“CMQ poison diagnostic authority is missing”“CMQ trusted poison ticket is incomplete”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status make_diagnostic(
    rdma_cmq_diagnostic_kind_e kind,
    rdma_cmq_ticket trusted_ticket,
    rdma_status failure,
    rdma_hw_image raw_cqe,
    output rdma_cmq_diagnostic diagnostic
  );
    rdma_status status;
    rdma_cmq_ticket ticket_snapshot;
    rdma_function_handle function_snapshot;
    rdma_handle cmq_snapshot_value;
    rdma_cmq_opcode_key opcode_snapshot;
    rdma_status failure_snapshot;
    rdma_hw_image raw_snapshot;

    diagnostic = null;
    if (failure == null || raw_cqe == null)
      return invalid_state("CMQ poison diagnostic authority is missing");
    ticket_snapshot = null;
    if (trusted_ticket != null) begin
      if (trusted_ticket.function_h == null ||
          trusted_ticket.cmq_h == null ||
          trusted_ticket.opcode_key == null)
        return invalid_state("CMQ trusted poison ticket is incomplete");
      function_snapshot = new("cmq_poison_ticket_function");
      function_snapshot.kind = trusted_ticket.function_h.kind;
      function_snapshot.function_uid =
        trusted_ticket.function_h.function_uid;
      function_snapshot.object_id = trusted_ticket.function_h.object_id;
      function_snapshot.generation = trusted_ticket.function_h.generation;
      cmq_snapshot_value = new("cmq_poison_ticket_cmq");
      cmq_snapshot_value.kind = trusted_ticket.cmq_h.kind;
      cmq_snapshot_value.function_uid = trusted_ticket.cmq_h.function_uid;
      cmq_snapshot_value.object_id = trusted_ticket.cmq_h.object_id;
      cmq_snapshot_value.generation = trusted_ticket.cmq_h.generation;
      opcode_snapshot = new("cmq_poison_ticket_opcode");
      opcode_snapshot.profile_name = trusted_ticket.opcode_key.profile_name;
      opcode_snapshot.opcode = trusted_ticket.opcode_key.opcode;
      opcode_snapshot.variant = trusted_ticket.opcode_key.variant;
      ticket_snapshot = new("cmq_poison_ticket");
      ticket_snapshot.command_id = trusted_ticket.command_id;
      ticket_snapshot.function_h = function_snapshot;
      ticket_snapshot.cmq_h = cmq_snapshot_value;
      ticket_snapshot.slot_sequence = trusted_ticket.slot_sequence;
      ticket_snapshot.sq_index = trusted_ticket.sq_index;
      ticket_snapshot.sq_wrap = trusted_ticket.sq_wrap;
      ticket_snapshot.opcode_key = opcode_snapshot;
      ticket_snapshot.absolute_deadline =
        trusted_ticket.absolute_deadline;
      status = ticket_snapshot.validate();
      if (status == null || !status.ok()) begin
        ticket_snapshot = null;
        return (status == null) ?
          invalid_state("CMQ poison ticket validation returned null") :
          status;
      end
    end
    failure_snapshot = new("cmq_poison_status");
    failure_snapshot.category = failure.category;
    failure_snapshot.code = failure.code;
    failure_snapshot.hardware_code = failure.hardware_code;
    failure_snapshot.hardware_code_valid = failure.hardware_code_valid;
    failure_snapshot.source_engine = failure.source_engine;
    failure_snapshot.function_uid = failure.function_uid;
    failure_snapshot.generation = failure.generation;
    failure_snapshot.resource_id = failure.resource_id;
    failure_snapshot.command_id = failure.command_id;
    failure_snapshot.wr_id = failure.wr_id;
    failure_snapshot.severity = failure.severity;
    failure_snapshot.retryable = failure.retryable;
    failure_snapshot.message = failure.message;
    raw_snapshot = new("cmq_poison_raw_cqe");
    raw_snapshot.bytes = raw_cqe.bytes;
    raw_snapshot.length = raw_cqe.length;
    raw_snapshot.alignment = raw_cqe.alignment;
    raw_snapshot.endian = raw_cqe.endian;
    raw_snapshot.image_kind = raw_cqe.image_kind;
    raw_snapshot.hardware_version = raw_cqe.hardware_version;
    raw_snapshot.function_generation = raw_cqe.function_generation;
    raw_snapshot.write_target_kind = raw_cqe.write_target_kind;
    raw_snapshot.backing_target = raw_cqe.backing_target;
    raw_snapshot.hmc_target = raw_cqe.hmc_target;
    raw_snapshot.bar_target = raw_cqe.bar_target;
    raw_snapshot.field_summary = raw_cqe.field_summary;
    diagnostic = new("cmq_poison_diagnostic");
    diagnostic.kind = kind;
    diagnostic.ticket = ticket_snapshot;
    diagnostic.status = failure_snapshot;
    diagnostic.raw_cqe = raw_snapshot;
    status = diagnostic.validate();
    if (status == null || !status.ok()) begin
      diagnostic = null;
      return invalid_state("CMQ poison diagnostic validation failed");
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_cmq_engine 中，clone_diagnostic 将 rhs 中 rdma_cmq_engine 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：source（输入）、snapshot（输出）；clone_diagnostic 读取 source、snapshot 并使用字段 snapshot，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：clone_diagnostic 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“CMQ poison diagnostic source is null”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status clone_diagnostic(
    rdma_cmq_diagnostic source,
    output rdma_cmq_diagnostic snapshot
  );
    snapshot = null;
    if (source == null)
      return invalid_state("CMQ poison diagnostic source is null");
    return make_diagnostic(
      source.kind, source.ticket, source.status, source.raw_cqe, snapshot
    );
  endfunction

  // 功能：在 rdma_cmq_engine 中，poison 构造并发布 detached 诊断证据，清空 late-final 队列后把 engine 原子切换为 POISONED。
  // 输入/输出及副作用：kind（输入）、message（输入）、raw_cqe（输入）、null（输入）；poison 可能更新本对象明确拥有的状态；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：poison 返回 RDMA_SC_CODEC_ERROR；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status poison(
    rdma_cmq_diagnostic_kind_e kind,
    string message,
    rdma_hw_image raw_cqe,
    rdma_cmq_ticket trusted_ticket = null
  );
    rdma_status status;
    rdma_status failure;
    rdma_cmq_diagnostic diagnostic;
    rdma_cmq_diagnostic poison_snapshot;

    late_final_fifo.delete();
    failure = rdma_status::make(RDMA_SC_CODEC_ERROR, message);
    failure.source_engine = RDMA_ENGINE_CMQ;
    if (prepared_binding != null) begin
      failure.function_uid = prepared_binding.function_uid;
      failure.generation = prepared_binding.generation;
    end
    if (cmq_snapshot != null && cmq_snapshot.handle != null)
      failure.resource_id = cmq_snapshot.handle.object_id;
    if (trusted_ticket != null)
      failure.command_id = trusted_ticket.command_id;

    // Stage both owned objects before publishing any poison state.  The FIFO
    // item is caller-owned after poll(), while last_poison remains engine
    // authority, so they must never share a root or nested object.
    status = make_diagnostic(
      kind, trusted_ticket, failure, raw_cqe, diagnostic
    );
    if (status == null || !status.ok() || diagnostic == null) begin
      // If a trusted ticket was itself inconsistent, preserve raw evidence
      // without claiming that association.  The fallback remains a complete,
      // detached diagnostic rather than publishing a partial poison state.
      failure.command_id = 0;
      status = make_diagnostic(
        RDMA_CMQ_DIAG_POISON, null, failure, raw_cqe, diagnostic
      );
      if (status == null || !status.ok() || diagnostic == null) begin
        engine_state = RDMA_CMQ_ENGINE_POISONED;
        return (status == null) ?
          invalid_state("CMQ poison diagnostic staging returned null") :
          status;
      end
    end
    status = clone_diagnostic(diagnostic, poison_snapshot);
    if (status == null || !status.ok() || poison_snapshot == null) begin
      engine_state = RDMA_CMQ_ENGINE_POISONED;
      return (status == null) ?
        invalid_state("CMQ last-poison staging returned null") : status;
    end
    last_poison = poison_snapshot;
    diagnostic_fifo.push_back(diagnostic);
    engine_state = RDMA_CMQ_ENGINE_POISONED;
    return failure;
  endfunction

  // 功能：在 rdma_cmq_engine 中，expire_locked 根据当前证据转换事务或恢复状态，并保持重试、复位和所有权边界一致。
  // 输入/输出及副作用：无显式参数；expire_locked 可能更新本对象明确拥有的状态；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：expire_locked 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“CMQ expiry slot authority is incomplete”“CMQ expiry slot ledger is inconsistent”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status expire_locked();
    rdma_status status;
    longint unsigned ledger_used;
    rdma_cmq_slot_record staged_records[CMQ_DEPTH];
    rdma_cmq_completion staged_completions[CMQ_DEPTH];
    rdma_cmq_batch_submission_record staged_batches[CMQ_DEPTH];
    rdma_cmq_batch_submission_item_record staged_items[CMQ_DEPTH];
    rdma_cmq_completion staged_journal_completions[CMQ_DEPTH];
    rdma_cmq_submission_state_e staged_batch_states[CMQ_DEPTH];
    bit staged_recovery_required[CMQ_DEPTH];
    string staged_command_keys[CMQ_DEPTH];
    int unsigned staged_count;

    status = poll_ledger_status(ledger_used);
    if (status == null || !status.ok())
      return (status == null) ?
        invalid_state("CMQ expiry ledger audit returned null status") : status;
    staged_count = 0;
    foreach (slots[i]) begin
      rdma_cmq_slot_record record;
      string software_key;
      string hardware_key;
      int unsigned token_index;

      record = slots[i];
      if (record == null || record.state != CMQ_SLOT_PUBLISHED)
        continue;
      if (record.ticket == null || record.ticket.function_h == null ||
          record.ticket.cmq_h == null || record.ticket.opcode_key == null ||
          record.expected == null ||
          $isunknown(record.ticket.absolute_deadline))
        return invalid_state("CMQ expiry slot authority is incomplete");
      if (record.ticket.absolute_deadline > $time)
        continue;
      hardware_key = entry_key(record.sq_index, record.sq_wrap);
      software_key = command_key(record.ticket);
      token_index = record.command_token;
      if (record.sq_index != i || record.ticket.sq_index != i ||
          record.ticket.slot_sequence != record.slot_sequence ||
          record.ticket.sq_wrap != record.sq_wrap ||
          record.ticket.command_id[4:0] != record.command_token ||
          !entry_registry.exists(hardware_key) ||
          entry_registry[hardware_key] != record ||
          !command_registry.exists(software_key) ||
          command_registry[software_key] != record ||
          token_index >= CMQ_DEPTH || !token_in_use[token_index])
        return invalid_state("CMQ expiry slot ledger is inconsistent");
      status = make_timeout_completion(
        record, staged_completions[staged_count]
      );
      if (status == null || !status.ok() ||
          staged_completions[staged_count] == null)
        return (status == null) ?
          invalid_state("CMQ timeout completion helper returned null status") :
          status;
      status = stage_runtime_journal_transition_locked(
        record, staged_completions[staged_count],
        RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED,
        RDMA_CMQ_COMPLETION_TIMEOUT,
        staged_batches[staged_count], staged_items[staged_count],
        staged_journal_completions[staged_count],
        staged_recovery_required[staged_count],
        staged_batch_states[staged_count]
      );
      if (status == null || !status.ok())
        return (status == null) ?
          invalid_state("CMQ timeout journal staging returned null status") :
          status;
      staged_records[staged_count] = record;
      staged_command_keys[staged_count] = software_key;
      staged_count++;
    end

    for (int unsigned i = 0; i < staged_count; i++) begin
      // journal completion 是恢复 authority，必须先于只用于交付顺序的 FIFO 发布。
      commit_runtime_journal_transition_locked(
        staged_batches[i], staged_items[i],
        staged_journal_completions[i],
        RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED,
        RDMA_CMQ_COMPLETION_TIMEOUT,
        staged_recovery_required[i], staged_batch_states[i]
      );
      terminal_fifo.push_back(staged_completions[i]);
      command_registry.delete(staged_command_keys[i]);
      staged_records[i].state = CMQ_SLOT_TIMED_OUT_QUARANTINED;
    end
    return rdma_status::success();
  endfunction

  // 功能：在 strict cancellation 前逐 slot 审计 generation、entry、
  //   command 与 token 的 exact membership；PUBLISHED 和 timeout quarantine 都必须
  //   保留各自的 token incarnation，只有 PUBLISHED 可留在 command registry。
  // 输入/输出及副作用：generation 是待取消的 Function generation；
  //   函数只读 runtime 账本并返回 rdma_status，损坏时 poison engine，
  //   不构造 cancellation completion。
  // 失败/边界：poll 粗审计失败、ticket/Function/CMQ/locator 不可信、
  //   slot/entry/key 不一致、published command 缺失、timeout command 残留、
  //   token bit/incarnation 不一致或总数不等时返回 INVALID_STATE 并 poison。
  protected function rdma_status strict_cancel_ledger_status(
    int unsigned generation
  );
    rdma_status status;
    longint unsigned ledger_used;
    int unsigned published_slot_count;
    int unsigned quarantined_slot_count;
    int unsigned token_count;

    status = poll_ledger_status(ledger_used);
    if (status == null || !status.ok())
      return (status == null) ?
        poison_status("CMQ cancel ledger audit returned null status") :
        status;
    published_slot_count = 0;
    quarantined_slot_count = 0;
    token_count = 0;
    foreach (slots[i]) begin
      rdma_cmq_slot_record record;
      string hardware_key;
      string software_key;

      if (token_in_use[i])
        token_count++;
      record = slots[i];
      if (record == null)
        continue;
      if ($isunknown(record.slot_sequence) ||
          $isunknown(record.sq_index) ||
          $isunknown(record.sq_wrap) ||
          $isunknown(record.state) ||
          $isunknown(record.command_token))
        return poison_status(
          "CMQ cancel slot identity contains unknown bits"
        );
      status = ticket_trust_status(record.ticket);
      if (status == null || !status.ok())
        return poison_status("CMQ cancel ticket authority is untrusted");
      if (record.expected == null ||
          !(record.state inside {
            CMQ_SLOT_PUBLISHED,
            CMQ_SLOT_COMPLETED,
            CMQ_SLOT_TIMED_OUT_QUARANTINED,
            CMQ_SLOT_LATE_COMPLETED,
            CMQ_SLOT_RESET_CANCELLED
          }) ||
          record.sq_index >= CMQ_DEPTH || record.sq_index != i ||
          record.sq_index != (record.slot_sequence % CMQ_DEPTH) ||
          record.sq_wrap !=
            ((record.slot_sequence / CMQ_DEPTH) % 2) ||
          record.ticket.sq_index != record.sq_index ||
          record.ticket.slot_sequence != record.slot_sequence ||
          record.ticket.sq_wrap != record.sq_wrap ||
          record.ticket.command_id[4:0] != record.command_token ||
          record.batch_key.len() == 0 ||
          !submission_journal.exists(record.batch_key) ||
          record.journal_item_index >=
            submission_journal[record.batch_key].items.size() ||
          record.ticket.function_h.generation != generation ||
          prepared_binding == null ||
          !prepared_binding.accepts(record.ticket.function_h) ||
          cmq_snapshot == null || cmq_snapshot.handle == null ||
          !same_handle(record.ticket.cmq_h, cmq_snapshot.handle))
        return poison_status("CMQ cancel slot authority is inconsistent");
      hardware_key = entry_key(record.sq_index, record.sq_wrap);
      if (!entry_registry.exists(hardware_key) ||
          entry_registry[hardware_key] != record)
        return poison_status("CMQ cancel entry registry is inconsistent");
      software_key = command_key(record.ticket);
      if (record.state == CMQ_SLOT_PUBLISHED) begin
        published_slot_count++;
        if (!command_registry.exists(software_key) ||
            command_registry[software_key] != record ||
            record.command_token >= CMQ_DEPTH ||
            !token_in_use[record.command_token] ||
            token_incarnation[record.command_token] !=
              record.ticket.command_id[63:5])
          return poison_status(
            "CMQ cancel published command ledger is inconsistent"
          );
      end
      else begin
        if (command_registry.exists(software_key))
          return poison_status(
            "CMQ cancel terminal command remains in the registry"
          );
        if (record.state inside {
              CMQ_SLOT_TIMED_OUT_QUARANTINED,
              CMQ_SLOT_RESET_CANCELLED
            }) begin
          quarantined_slot_count++;
          if (record.command_token >= CMQ_DEPTH ||
              !token_in_use[record.command_token] ||
              token_incarnation[record.command_token] !=
                record.ticket.command_id[63:5])
            return poison_status(
              "CMQ cancel quarantined token ledger is inconsistent"
            );
        end
      end
    end
    if (published_slot_count != command_registry.num() ||
        published_slot_count + quarantined_slot_count != token_count)
      return poison_status(
        "CMQ cancel reserved command membership is inconsistent"
      );
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_cmq_engine 中，recovery_record_is_trusted 根据当前证据转换事务或恢复状态，并保持重试、复位和所有权边界一致。
  // 输入/输出及副作用：record（输入）、slot_index（输入）、generation（输入）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：当前状态不允许、epoch/generation 过期或恢复证据不完整时返回错误；不得跳过隔离步骤。
  protected function bit recovery_record_is_trusted(
    rdma_cmq_slot_record record,
    int unsigned slot_index,
    int unsigned generation
  );
    rdma_status status;

    if (record == null || record.ticket == null ||
        $isunknown(record.slot_sequence) ||
        $isunknown(record.sq_index) ||
        $isunknown(record.sq_wrap) ||
        $isunknown(record.state) ||
        $isunknown(record.command_token))
      return 1'b0;
    status = ticket_trust_status(record.ticket);
    if (status == null || !status.ok())
      return 1'b0;
    if (record.state != CMQ_SLOT_PUBLISHED ||
        prepared_binding == null ||
        !prepared_binding.accepts(record.ticket.function_h) ||
        cmq_snapshot == null || cmq_snapshot.handle == null ||
        !same_handle(record.ticket.cmq_h, cmq_snapshot.handle) ||
        record.ticket.function_h.generation != generation ||
        record.sq_index >= CMQ_DEPTH || record.sq_index != slot_index ||
        record.sq_index != (record.slot_sequence % CMQ_DEPTH) ||
        record.sq_wrap != ((record.slot_sequence / CMQ_DEPTH) % 2) ||
        record.ticket.sq_index != record.sq_index ||
        record.ticket.slot_sequence != record.slot_sequence ||
        record.ticket.sq_wrap != record.sq_wrap ||
        record.ticket.command_id[4:0] != record.command_token)
      return 1'b0;
    return 1'b1;
  endfunction

  // 功能：在 rdma_cmq_engine 中，cancel_generation_locked 先审计整张 runtime
  //   ledger，再把仍为 PUBLISHED 的 exact journal item 转成 reset cancellation，
  //   让旧 generation 进入 QUIESCED；timeout tombstone 与其 slot/token authority
  //   继续保留，等待 late completion 或 observed reset 再隔离。
  // 输入/输出及副作用：generation、recover_poisoned_ledger 为输入；严格路径先
  //   预建 completion/journal transition，再在锁内提交 FIFO、command registry 与
  //   slot state；poison recovery 路径仅用于 shutdown 的 best-effort 清账。
  // 失败/边界：generation 不匹配返回 STALE_GENERATION；严格审计、slot/entry/token
  //   authority、journal predecessor 或 completion snapshot 任一不完整时 fail closed，
  //   不发布 FIFO、不修改 journal/runtime；timeout/reset quarantine 不会被重复取消。
  protected function rdma_status cancel_generation_locked(
    int unsigned generation,
    bit recover_poisoned_ledger
  );
    rdma_status status;
    rdma_cmq_completion staged_completions[CMQ_DEPTH];
    rdma_cmq_batch_submission_record staged_batches[CMQ_DEPTH];
    rdma_cmq_batch_submission_item_record staged_items[CMQ_DEPTH];
    rdma_cmq_completion staged_journal_completions[CMQ_DEPTH];
    rdma_cmq_submission_state_e staged_batch_states[CMQ_DEPTH];
    bit staged_recovery_required[CMQ_DEPTH];
    rdma_cmq_slot_record staged_records[CMQ_DEPTH];
    string staged_command_key_values[CMQ_DEPTH];
    bit recovery_command_keys[string];
    int unsigned staged_count;

    if (prepared_binding == null)
      return invalid_state("CMQ generation authority is missing");
    if (generation != prepared_binding.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ cancel generation does not match current generation"
      );

    if (!recover_poisoned_ledger) begin
      status = strict_cancel_ledger_status(generation);
      if (status == null || !status.ok())
        return (status == null) ?
          poison_status("CMQ cancel ledger audit returned null status") :
          status;
    end

    staged_count = 0;
    if (recover_poisoned_ledger) begin
      foreach (slots[i]) begin
        rdma_cmq_slot_record record;
        string software_key;

        record = slots[i];
        if (!recovery_record_is_trusted(record, i, generation))
          continue;
        software_key = command_key(record.ticket);
        if (recovery_command_keys.exists(software_key))
          continue;
        status = make_cancel_completion(
          record, staged_completions[staged_count]
        );
        if (status != null && status.ok() &&
            staged_completions[staged_count] != null) begin
          recovery_command_keys[software_key] = 1'b1;
          staged_count++;
        end
      end
    end
    else begin
      foreach (slots[i]) begin
        rdma_cmq_slot_record record;

        record = slots[i];
        if (record == null)
          continue;
        if (record.state != CMQ_SLOT_PUBLISHED)
          continue;
        status = make_cancel_completion(
          record, staged_completions[staged_count]
        );
        if (status == null || !status.ok() ||
            staged_completions[staged_count] == null)
          return (status == null) ?
            invalid_state("CMQ cancel completion helper returned null") :
            status;
        status = stage_runtime_journal_transition_locked(
          record, staged_completions[staged_count],
          RDMA_CMQ_SUBMISSION_RESET_QUARANTINED,
          RDMA_CMQ_COMPLETION_RESET_CANCELLED,
          staged_batches[staged_count], staged_items[staged_count],
          staged_journal_completions[staged_count],
          staged_recovery_required[staged_count],
          staged_batch_states[staged_count]
        );
        if (status == null || !status.ok())
          return (status == null) ?
            invalid_state("CMQ cancel journal staging returned null status") :
            status;
        staged_records[staged_count] = record;
        staged_command_key_values[staged_count] = command_key(record.ticket);
        staged_count++;
      end
    end

    if (recover_poisoned_ledger) begin
      // Shutdown/poison recovery has no completion output contract.  It may
      // conservatively discard trusted cancellation evidence while clearing
      // every runtime container after the caller has retained release authority.
      for (int unsigned i = 0; i < staged_count; i++)
        terminal_fifo.push_back(staged_completions[i]);
      foreach (slots[i])
        slots[i] = null;
      foreach (token_in_use[i])
        token_in_use[i] = 1'b0;
      command_registry.delete();
      entry_registry.delete();
      publish_seq = 0;
      retire_seq = 0;
      cq_consume_seq = 0;
      profile_image_format_valid = 1'b0;
      profile_image_endian = RDMA_ENDIAN_LITTLE;
      profile_hardware_version = 0;
    end
    else begin
      // Journal evidence is committed before delivery FIFO publication.  The
      // runtime slot/entry/token graph remains authoritative until a later
      // reset or shutdown explicitly proves old hardware isolation.
      for (int unsigned i = 0; i < staged_count; i++) begin
        commit_runtime_journal_transition_locked(
          staged_batches[i], staged_items[i],
          staged_journal_completions[i],
          RDMA_CMQ_SUBMISSION_RESET_QUARANTINED,
          RDMA_CMQ_COMPLETION_RESET_CANCELLED,
          staged_recovery_required[i], staged_batch_states[i]
        );
        terminal_fifo.push_back(staged_completions[i]);
        command_registry.delete(staged_command_key_values[i]);
        staged_records[i].state = CMQ_SLOT_RESET_CANCELLED;
      end
    end
    engine_state = RDMA_CMQ_ENGINE_QUIESCED;
    return rdma_status::success();
  endfunction

  // 功能：prospective_retirement_status 校验 prospective_record、prospective_retire_seq 与当前对象状态的一致性，并显式处理“CMQ prospective retirement record is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：prospective_record（输入）、prospective_retire_seq（输出）；prospective_retirement_status 读取 prospective_record、prospective_retire_seq 并使用字段 prospective_retire_seq、index、record，并写入 prospective_retire_seq；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：prospective_retirement_status 返回 函数体规定的失败状态；具体拒绝条件包括 “CMQ prospective retirement record is null”；“CMQ retirement slot ledger is inconsistent”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status prospective_retirement_status(
    rdma_cmq_slot_record prospective_record,
    output longint unsigned prospective_retire_seq
  );
    prospective_retire_seq = retire_seq;
    if (prospective_record == null)
      return invalid_state("CMQ prospective retirement record is null");
    if (prospective_record.slot_sequence < retire_seq ||
        prospective_record.slot_sequence >= publish_seq ||
        prospective_record.sq_index !=
          (prospective_record.slot_sequence % CMQ_DEPTH) ||
        prospective_record.sq_wrap !=
          ((prospective_record.slot_sequence / CMQ_DEPTH) & 1'b1))
      return invalid_state(
        "CMQ prospective retirement record incarnation is inconsistent"
      );
    while (prospective_retire_seq < publish_seq) begin
      int unsigned index;
      rdma_cmq_slot_record record;

      index = prospective_retire_seq % CMQ_DEPTH;
      record = slots[index];
      if (record == null ||
          record.slot_sequence != prospective_retire_seq ||
          record.sq_index != index ||
          record.sq_wrap !=
            ((prospective_retire_seq / CMQ_DEPTH) & 1'b1))
        return invalid_state("CMQ retirement slot ledger is inconsistent");
      if (record != prospective_record &&
          !(record.state inside {
            CMQ_SLOT_COMPLETED,
            CMQ_SLOT_LATE_COMPLETED,
            CMQ_SLOT_RESET_CANCELLED
          }))
        break;
      prospective_retire_seq++;
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_cmq_engine 中，commit_retired_prefix 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：prospective_retire_seq（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过
  //   output 返回结果。
  // 失败/边界：commit_retired_prefix 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  protected function void commit_retired_prefix(
    longint unsigned prospective_retire_seq
  );
    while (retire_seq < prospective_retire_seq) begin
      int unsigned index;

      index = retire_seq % CMQ_DEPTH;
      entry_registry.delete(entry_key(index, slots[index].sq_wrap));
      slots[index] = null;
      retire_seq++;
    end
  endfunction

  // 功能：在 rdma_cmq_engine 中由 same_handle 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_handle 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_handle(rdma_handle lhs, rdma_handle rhs);
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.same_instance(rhs);
  endfunction

  // 功能：在 rdma_cmq_engine 中由 same_bdf 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_bdf 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_bdf(rdma_bdf_t lhs, rdma_bdf_t rhs);
    return lhs == rhs;
  endfunction

  // 功能：在 rdma_cmq_engine 中，clone_binding_snapshot 将 rhs 中 rdma_cmq_engine 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：source（输入）、snapshot（输出）；clone_binding_snapshot 读取 source、snapshot 并使用字段 snapshot、cloned_object，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：clone_binding_snapshot 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“CMQ Function binding is null”“CMQ Function binding snapshot clone failed”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status clone_binding_snapshot(
    rdma_function_binding source,
    output rdma_function_binding snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return invalid_argument("CMQ Function binding is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object)) begin
      snapshot = null;
      return invalid_state("CMQ Function binding snapshot clone failed");
    end
    return rdma_status::success();
  endfunction

  // 功能：validate_binding_owner 校验 binding、lifecycle_name 与当前对象状态的一致性，并显式处理“CMQ Function binding is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：binding（输入）、lifecycle_name（输入）；validate_binding_owner 读取 binding、lifecycle_name 并使用字段 expected_owner；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  protected function rdma_status validate_binding_owner(
    rdma_function_binding binding,
    string lifecycle_name
  );
    rdma_function_handle expected_owner;

    if (binding == null)
      return invalid_argument("CMQ Function binding is null");
    expected_owner = binding.make_handle();
    if (binding.owner_h == null ||
        !same_handle(binding.owner_h, expected_owner))
      return invalid_state({lifecycle_name,
                            " Function binding owner identity is invalid"});
    return rdma_status::success();
  endfunction

  // 功能：prepared_binding_status 校验 binding 与当前对象状态的一致性，并显式处理“CMQ Function binding is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：binding（输入）；prepared_binding_status 可能更新本对象明确拥有的状态；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：prepared_binding_status 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“CMQ Function binding is null”“CMQ prepare requires a PREPARED binding”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status prepared_binding_status(
    rdma_function_binding binding
  );
    rdma_status status;

    if (binding == null)
      return invalid_argument("CMQ Function binding is null");
    if (binding.state != RDMA_BIND_PREPARED)
      return invalid_state("CMQ prepare requires a PREPARED binding");
    status = binding.validate();
    if (status == null)
      return invalid_state("CMQ PREPARED binding returned null status");
    if (!status.ok())
      return status;
    return validate_binding_owner(binding, "PREPARED");
  endfunction

  // 功能：active_binding_status 校验 binding 与当前对象状态的一致性，并显式处理“CMQ active Function binding is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：binding（输入）；active_binding_status 读取 binding 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：active_binding_status 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“CMQ active Function binding is null”“CMQ activate requires an ACTIVE binding”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status active_binding_status(
    rdma_function_binding binding
  );
    rdma_status status;

    if (binding == null)
      return invalid_argument("CMQ active Function binding is null");
    if (binding.state != RDMA_BIND_ACTIVE)
      return invalid_state("CMQ activate requires an ACTIVE binding");
    status = binding.validate();
    if (status == null)
      return invalid_state("CMQ ACTIVE binding returned null status");
    if (!status.ok())
      return status;
    return validate_binding_owner(binding, "ACTIVE");
  endfunction

  // 功能：在 rdma_cmq_engine 中，clone_cmq_snapshot 将 rhs 中 rdma_cmq_engine 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：source（输入）、snapshot（输出）；clone_cmq_snapshot 读取 source、snapshot 并使用字段 snapshot、cloned_object，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：clone_cmq_snapshot 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“CMQ resource is null”“CMQ resource snapshot clone failed”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status clone_cmq_snapshot(
    rdma_cmq source,
    output rdma_cmq snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return invalid_argument("CMQ resource is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object)) begin
      snapshot = null;
      return invalid_state("CMQ resource snapshot clone failed");
    end
    return rdma_status::success();
  endfunction

  // 功能：cmq_resource_status 校验 cmq、binding 与当前对象状态的一致性，并显式处理“CMQ resource is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：cmq（输入）、binding（输入）；cmq_resource_status 读取 cmq、binding 并使用字段 status、expected_owner；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：cmq_resource_status 返回 RDMA_SC_STALE_GENERATION、RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“CMQ resource is null”“CMQ resource returned null status”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status cmq_resource_status(
    rdma_cmq cmq,
    rdma_function_binding binding
  );
    rdma_status status;
    rdma_function_handle expected_owner;

    if (cmq == null)
      return invalid_argument("CMQ resource is null");
    status = cmq.validate();
    if (status == null)
      return invalid_state("CMQ resource returned null status");
    if (!status.ok())
      return status;
    if (cmq.state != RDMA_RESOURCE_ALLOCATED)
      return invalid_state("CMQ resource is not ALLOCATED");
    if (cmq.depth != CMQ_DEPTH)
      return invalid_argument("CMQ queue depth must be 32");
    expected_owner = binding.make_handle();
    if (cmq.owner == null || !same_handle(cmq.owner, expected_owner))
      return invalid_argument("CMQ owner does not match Function binding");
    if (cmq.handle == null || cmq.handle.kind != RDMA_RESOURCE_CMQ)
      return invalid_argument("CMQ resource handle is invalid");
    if (cmq.handle.function_uid != expected_owner.function_uid)
      return invalid_argument("CMQ handle Function UID does not match owner");
    if (cmq.handle.generation != expected_owner.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ handle Function generation does not match owner"
      );
    return rdma_status::success();
  endfunction

  // 功能：make_request_context 创建独立的 rdma_status；根据 binding、cmq、pasid_valid、pasid、request_context 设置字段 request_context、request_context.function_h、request_context.requester_bdf、request_context.pasid_valid、request_context.pasid、request_context.dma_domain_valid、request_context.dma_domain_id、request_context.route、request_context.reset_epoch、request_context.owner_h、status，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、cmq（输入）、pasid_valid（输入）、pasid（输入）、request_context（输出）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：make_request_context 返回 RDMA_SC_DMA_TRANSLATION；具体拒绝条件包括 “CMQ DMA request context construction failed”；“CMQ DMA Function handle construction failed”；“CMQ DMA request context returned null status”；“CMQ PASID does not match Function queue DMA authority”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status make_request_context(
    rdma_function_binding binding,
    rdma_cmq cmq,
    bit pasid_valid,
    bit [19:0] pasid,
    output rdma_dma_request_context request_context
  );
    rdma_status status;
    rdma_function_identity identity;
    request_context = rdma_dma_request_context::type_id::create(
      "cmq_dma_request_context"
    );
    if (request_context == null)
      return invalid_state("CMQ DMA request context construction failed");
    request_context.function_h = binding.make_handle();
    if (request_context.function_h == null)
      return invalid_state("CMQ DMA Function handle construction failed");
    identity = binding.function_identity_snapshot();
    if (identity == null)
      return invalid_state("CMQ DMA Function identity snapshot failed");
    if (pasid_valid != binding.queue_dma.pasid_valid ||
        (pasid_valid ? pasid : '0) != binding.queue_dma.pasid)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ PASID does not match Function queue DMA authority"
      );
    request_context.requester_bdf = binding.queue_dma.requester_bdf;
    request_context.pasid_valid = binding.queue_dma.pasid_valid;
    request_context.pasid = binding.queue_dma.pasid;
    request_context.dma_domain_valid = binding.queue_dma.dma_domain_valid;
    request_context.dma_domain_id = binding.queue_dma.dma_domain_id;
    // Host-memory router 需要完整 fabric route 和 Function reset epoch；
    // 将 identity 快照投影到 request context，避免 CMQ 走 router 时被当作
    // 缺少路由/代际证据的请求拒绝。
    request_context.route = identity.route_key();
    request_context.route_valid = 1'b1;
    request_context.reset_epoch = identity.reset_epoch;
    request_context.epoch_valid = 1'b1;
    request_context.owner_h = rdma_clone_handle_value(
      cmq.handle, "CMQ DMA owner"
    );
    status = request_context.validate();
    if (status == null)
      return invalid_state("CMQ DMA request context returned null status");
    return status;
  endfunction

  // 功能：mapping_authority_status 校验 mapping、request_context 与当前对象状态的一致性，并显式处理“CMQ host memory returned a null mapping”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：mapping（输入）、request_context（输入）；mapping_authority_status 读取 mapping、request_context 并使用字段 expected_permissions；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：mapping_authority_status 返回 RDMA_SC_DMA_TRANSLATION、RDMA_SC_STALE_GENERATION、RDMA_SC_DMA_PERMISSION、RDMA_SC_INVALID_STATE；典型拒绝条件为“CMQ host memory returned a null mapping”“CMQ DMA authority context is missing”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status mapping_authority_status(
    rdma_dma_mapping mapping,
    rdma_dma_request_context request_context
  );
    rdma_dma_permission_t expected_permissions;

    expected_permissions = '{
      device_read: 1'b1,
      device_write: 1'b1,
      atomic: 1'b0
    };
    if (mapping == null)
      return invalid_state("CMQ host memory returned a null mapping");
    if (request_context == null)
      return invalid_state("CMQ DMA authority context is missing");
    if (mapping.function_h == null)
      return invalid_state("CMQ mapping Function authority is missing");
    if (request_context.function_h == null)
      return invalid_state("CMQ request Function authority is missing");
    if (mapping.function_h.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ mapping Function handle kind is invalid"
      );
    if (mapping.function_h.function_uid !=
          request_context.function_h.function_uid ||
        mapping.function_h.object_id != request_context.function_h.object_id)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ mapping Function authority does not match request"
      );
    if (mapping.function_h.generation !=
        request_context.function_h.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ mapping Function generation does not match request"
      );
    if (!same_bdf(mapping.requester_bdf,
                  request_context.requester_bdf))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ mapping requester BDF does not match request"
      );
    if (mapping.pasid_valid != request_context.pasid_valid)
      return rdma_status::make(
        RDMA_SC_DMA_PERMISSION,
        "CMQ mapping PASID-valid authority does not match request"
      );
    if (mapping.pasid != request_context.pasid)
      return rdma_status::make(
        RDMA_SC_DMA_PERMISSION,
        "CMQ mapping PASID authority does not match request"
      );
    if (mapping.dma_domain_valid != request_context.dma_domain_valid)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ mapping DMA-domain-valid authority does not match request"
      );
    if (mapping.dma_domain_id != request_context.dma_domain_id)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ mapping DMA domain authority does not match request"
      );
    if (mapping.owner_h == null || request_context.owner_h == null ||
        !same_handle(mapping.owner_h, request_context.owner_h))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ mapping owner authority does not match request"
      );
    if (mapping.state != RDMA_MAPPING_ACTIVE)
      return invalid_state("CMQ backing mapping is not ACTIVE");
    if (mapping.size != BACKING_BYTES)
      return invalid_state("CMQ backing mapping size is not 4096 bytes");
    if (mapping.direction != RDMA_DMA_BIDIRECTIONAL)
      return invalid_state("CMQ backing mapping is not bidirectional");
    if (mapping.permissions != expected_permissions)
      return rdma_status::make(
        RDMA_SC_DMA_PERMISSION,
        "CMQ backing mapping permissions are not exactly bidirectional"
      );
    if ((mapping.iova.value & (BACKING_BYTES - 1'b1)) != 0 ||
        (mapping.backing_addr.value & (BACKING_BYTES - 1'b1)) != 0)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ backing mapping is not 4096-byte aligned"
      );
    if (mapping.iova.value >
          (64'hffff_ffff_ffff_ffff - (BACKING_BYTES - 1'b1)) ||
        mapping.backing_addr.value >
          (64'hffff_ffff_ffff_ffff - (BACKING_BYTES - 1'b1)))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ backing mapping range overflows"
      );
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_cmq_engine 中，clone_function_handle_fields 将 rhs 中 rdma_cmq_engine 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：source（输入）、name（输入）、result（输出）；clone_function_handle_fields 读取 source、name、result 并使用字段 result、result.kind、result.function_uid、result.object_id、result.generation，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：clone_function_handle_fields 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“CMQ runtime Function source is null”“CMQ runtime Function construction failed”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status clone_function_handle_fields(
    rdma_function_handle source,
    string name,
    output rdma_function_handle result
  );
    result = null;
    if (source == null)
      return invalid_state("CMQ runtime Function source is null");
    result = rdma_function_handle::type_id::create(name);
    if (result == null)
      return invalid_state("CMQ runtime Function construction failed");
    result.kind = source.kind;
    result.function_uid = source.function_uid;
    result.object_id = source.object_id;
    result.generation = source.generation;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_cmq_engine 中，clone_handle_fields 将 rhs 中 rdma_cmq_engine 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：source（输入）、name（输入）、result（输出）；clone_handle_fields 读取 source、name、result 并使用字段 result、result.kind、result.function_uid、result.object_id、result.generation，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：clone_handle_fields 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“CMQ runtime handle source is null”“CMQ runtime handle construction failed”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status clone_handle_fields(
    rdma_handle source,
    string name,
    output rdma_handle result
  );
    result = null;
    if (source == null)
      return invalid_state("CMQ runtime handle source is null");
    result = rdma_handle::type_id::create(name);
    if (result == null)
      return invalid_state("CMQ runtime handle construction failed");
    result.kind = source.kind;
    result.function_uid = source.function_uid;
    result.object_id = source.object_id;
    result.generation = source.generation;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_cmq_engine 中，snapshot_failure 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：failure_code（输入）、message（输入）；snapshot_failure 读取 failure_code、message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：snapshot_failure 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  protected function rdma_status snapshot_failure(
    rdma_status_code_e failure_code,
    string message
  );
    return rdma_status::make(failure_code, message);
  endfunction

  // 功能：在 rdma_cmq_engine 中由 same_byte_queue 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_byte_queue 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_byte_queue(
    byte unsigned lhs[$],
    byte unsigned rhs[$]
  );
    if (lhs.size() != rhs.size())
      return 1'b0;
    foreach (lhs[i])
      if (lhs[i] != rhs[i])
        return 1'b0;
    return 1'b1;
  endfunction

  // 功能：在 rdma_cmq_engine 中由 same_string_queue 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_string_queue 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_string_queue(
    string lhs[$],
    string rhs[$]
  );
    if (lhs.size() != rhs.size())
      return 1'b0;
    foreach (lhs[i])
      if (lhs[i] != rhs[i])
        return 1'b0;
    return 1'b1;
  endfunction

  // 功能：在 rdma_cmq_engine 中由 same_image_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_image_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_image_value(
    rdma_hw_image lhs,
    rdma_hw_image rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return same_byte_queue(lhs.bytes, rhs.bytes) &&
           lhs.length == rhs.length &&
           lhs.alignment == rhs.alignment &&
           lhs.endian == rhs.endian &&
           lhs.image_kind == rhs.image_kind &&
           lhs.hardware_version == rhs.hardware_version &&
           lhs.function_generation == rhs.function_generation &&
           lhs.write_target_kind == rhs.write_target_kind &&
           lhs.backing_target.value == rhs.backing_target.value &&
           lhs.hmc_target.value == rhs.hmc_target.value &&
           lhs.bar_target.value == rhs.bar_target.value &&
           same_string_queue(lhs.field_summary, rhs.field_summary);
  endfunction

  // 功能：在 rdma_cmq_engine 中由 same_expected_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_expected_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_expected_value(
    rdma_cmq_expected_response lhs,
    rdma_cmq_expected_response rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.hardware_opcode == rhs.hardware_opcode &&
           lhs.variant == rhs.variant;
  endfunction

  // 功能：在 rdma_cmq_engine 中由 same_opcode_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_opcode_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_opcode_value(
    rdma_cmq_opcode_key lhs,
    rdma_cmq_opcode_key rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.profile_name == rhs.profile_name &&
           lhs.opcode == rhs.opcode && lhs.variant == rhs.variant;
  endfunction

  // 功能：在 rdma_cmq_engine 中由 same_mapping_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_mapping_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_mapping_value(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null ||
        lhs.function_h == null || rhs.function_h == null ||
        lhs.owner_h == null || rhs.owner_h == null)
      return 1'b0;
    return lhs.function_h.same_instance(rhs.function_h) &&
           lhs.requester_bdf == rhs.requester_bdf &&
           lhs.pasid_valid == rhs.pasid_valid &&
           lhs.pasid == rhs.pasid &&
           lhs.dma_domain_valid == rhs.dma_domain_valid &&
           lhs.dma_domain_id == rhs.dma_domain_id &&
           lhs.backing_addr.value == rhs.backing_addr.value &&
           lhs.iova.value == rhs.iova.value &&
           lhs.size == rhs.size &&
           lhs.direction == rhs.direction &&
           lhs.permissions == rhs.permissions &&
           lhs.state == rhs.state &&
           lhs.owner_h.same_instance(rhs.owner_h);
  endfunction

  // 功能：在 rdma_cmq_engine 中由 same_ticket_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_ticket_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_ticket_value(
    rdma_cmq_ticket lhs,
    rdma_cmq_ticket rhs
  );
    if (lhs == null || rhs == null ||
        lhs.function_h == null || rhs.function_h == null ||
        lhs.cmq_h == null || rhs.cmq_h == null)
      return 1'b0;
    return lhs.command_id == rhs.command_id &&
           lhs.function_h.same_instance(rhs.function_h) &&
           lhs.cmq_h.same_instance(rhs.cmq_h) &&
           lhs.slot_sequence == rhs.slot_sequence &&
           lhs.sq_index == rhs.sq_index &&
           lhs.sq_wrap == rhs.sq_wrap &&
           same_opcode_value(lhs.opcode_key, rhs.opcode_key) &&
           lhs.absolute_deadline == rhs.absolute_deadline;
  endfunction

  // 功能：在 rdma_cmq_engine 中由 same_dependency_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_dependency_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_dependency_value(
    rdma_doorbell_dependency lhs,
    rdma_doorbell_dependency rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.dependency_id == rhs.dependency_id &&
           lhs.stage == rhs.stage &&
           same_mapping_value(lhs.mapping, rhs.mapping) &&
           lhs.relative_offset == rhs.relative_offset &&
           same_image_value(lhs.image, rhs.image) &&
           lhs.ready == rhs.ready;
  endfunction

  // 功能：在 rdma_cmq_engine 中，handle_value_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：handle（输入）；handle_value_key 可能更新本对象明确拥有的状态；函数返回 string，不取得调用方资源所有权。
// 失败/边界：handle_value_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function automatic string handle_value_key(rdma_handle handle);
    if (handle == null)
      return "<null-handle>";
    return $sformatf("%0d:%016h:%08h:%08h", handle.kind,
                     handle.function_uid, handle.object_id,
                     handle.generation);
  endfunction

  // 功能：判断 has_exact_object_type 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：value（输入）、expected_type（输入）；has_exact_object_type 读取 value、expected_type 并使用字段 actual_type；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：has_exact_object_type 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected function automatic bit has_exact_object_type(
    uvm_object value,
    uvm_object_wrapper expected_type
  );
    uvm_object_wrapper actual_type;

    if (value == null || expected_type == null)
      return 1'b0;
    actual_type = value.get_object_type();
    return actual_type != null && actual_type == expected_type;
  endfunction

  // 功能：判断 has_optional_exact_object_type 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：value（输入）、expected_type（输入）；has_optional_exact_object_type 读取 value、expected_type 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：has_optional_exact_object_type 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  protected function automatic bit has_optional_exact_object_type(
    uvm_object value,
    uvm_object_wrapper expected_type
  );
    return value == null || has_exact_object_type(value, expected_type);
  endfunction

  // 功能：在 rdma_cmq_engine 中，core_body_shell_is_exact 逐字段核对快照、嵌套引用和 authority 值，确认复制结果既等值又无可变别名。
  // 输入/输出及副作用：body（输入）；core_body_shell_is_exact 读取 body 并使用字段 rdma_function_handle、rdma_handle、rdma_urc_queue_config、rdma_page_table_layout、rdma_ring_position、rdma_mr_page_layout、rdma_cmq_sqe_model、rdma_qpc_model；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：core_body_shell_is_exact 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function automatic bit core_body_shell_is_exact(
    rdma_hw_model body
  );
    rdma_cmq_sqe_model sqe;
    rdma_qpc_model qpc;
    rdma_qpc_urc_ext urc_ext;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;

    if (body == null)
      return 1'b0;
    if (has_exact_object_type(body, rdma_cmq_sqe_model::get_type())) begin
      if (!$cast(sqe, body)) return 1'b0;
      return has_exact_object_type(
               sqe.function_h, rdma_function_handle::get_type()
             ) &&
             has_optional_exact_object_type(
               sqe.target_h, rdma_handle::get_type()
             );
    end
    if (has_exact_object_type(body, rdma_qpc_model::get_type())) begin
      if (!$cast(qpc, body)) return 1'b0;
      if (!has_exact_object_type(qpc.qp_h, rdma_handle::get_type()) ||
          !has_exact_object_type(qpc.pd_h, rdma_handle::get_type()) ||
          !has_exact_object_type(qpc.send_cq_h, rdma_handle::get_type()) ||
          !has_exact_object_type(qpc.recv_cq_h, rdma_handle::get_type()) ||
          !has_optional_exact_object_type(
            qpc.srq_h, rdma_handle::get_type()
          ) ||
          !has_exact_object_type(
            qpc.address_vector, rdma_address_vector::get_type()
          ) ||
          !has_exact_object_type(
            qpc.behavior, rdma_qpc_behavior::get_type()
          ))
        return 1'b0;
      if (has_exact_object_type(qpc.transport_ext,
                                rdma_qpc_rc_ext::get_type()) ||
          has_exact_object_type(qpc.transport_ext,
                                rdma_qpc_ud_ext::get_type()))
        return 1'b1;
      if (!has_exact_object_type(qpc.transport_ext,
                                 rdma_qpc_urc_ext::get_type()) ||
          !$cast(urc_ext, qpc.transport_ext))
        return 1'b0;
      return has_exact_object_type(
        urc_ext.queues, rdma_urc_queue_config::get_type()
      );
    end
    if (has_exact_object_type(body, rdma_cqc_model::get_type())) begin
      if (!$cast(cqc, body)) return 1'b0;
      return has_exact_object_type(cqc.cq_h, rdma_handle::get_type()) &&
             has_optional_exact_object_type(
               cqc.ceq_h, rdma_handle::get_type()
             ) &&
             has_exact_object_type(
               cqc.page_layout, rdma_page_table_layout::get_type()
             ) &&
             has_exact_object_type(
               cqc.producer, rdma_ring_position::get_type()
             ) &&
             has_exact_object_type(
               cqc.consumer, rdma_ring_position::get_type()
             );
    end
    if (has_exact_object_type(body, rdma_mrt_model::get_type())) begin
      if (!$cast(mrt, body)) return 1'b0;
      return has_exact_object_type(mrt.mr_h, rdma_handle::get_type()) &&
             has_exact_object_type(mrt.pd_h, rdma_handle::get_type()) &&
             has_exact_object_type(
               mrt.page_layout, rdma_mr_page_layout::get_type()
             );
    end
    if (has_exact_object_type(body, rdma_srqc_model::get_type())) begin
      if (!$cast(srqc, body)) return 1'b0;
      return has_exact_object_type(srqc.srq_h, rdma_handle::get_type()) &&
             has_exact_object_type(srqc.pd_h, rdma_handle::get_type()) &&
             has_exact_object_type(
               srqc.producer, rdma_ring_position::get_type()
             );
    end
    if (has_exact_object_type(body, rdma_ceqc_model::get_type())) begin
      if (!$cast(ceqc, body)) return 1'b0;
      return has_exact_object_type(ceqc.ceq_h, rdma_handle::get_type()) &&
             has_exact_object_type(
               ceqc.page_layout, rdma_page_table_layout::get_type()
             ) &&
             has_exact_object_type(
               ceqc.producer, rdma_ring_position::get_type()
             ) &&
             has_exact_object_type(
               ceqc.consumer, rdma_ring_position::get_type()
             );
    end
    if (has_exact_object_type(body, rdma_aeqc_model::get_type())) begin
      if (!$cast(aeqc, body)) return 1'b0;
      return has_exact_object_type(aeqc.aeq_h, rdma_handle::get_type()) &&
             has_exact_object_type(
               aeqc.page_layout, rdma_page_table_layout::get_type()
             ) &&
             has_exact_object_type(
               aeqc.producer, rdma_ring_position::get_type()
             ) &&
             has_exact_object_type(
               aeqc.consumer, rdma_ring_position::get_type()
             );
    end
    return 1'b0;
  endfunction

  // 功能：在 rdma_cmq_engine 中，nested_value_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：value（输入）；nested_value_key 读取 value 并使用字段 result；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：nested_value_key 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function automatic string nested_value_key(uvm_object value);
    rdma_handle handle;
    rdma_ring_position ring;
    rdma_page_table_layout page_layout;
    rdma_address_vector address_vector;
    rdma_urc_queue_config queues;
    rdma_mr_page_layout mr_page_layout;
    rdma_qpc_behavior behavior;
    rdma_qpc_rc_ext rc_ext;
    rdma_qpc_ud_ext ud_ext;
    rdma_qpc_urc_ext urc_ext;
    string result;

    if (value == null)
      return "<null-object>";
    if (has_exact_object_type(value, rdma_handle::get_type()) &&
        $cast(handle, value))
      return {"handle:", handle_value_key(handle)};
    if (has_exact_object_type(value, rdma_ring_position::get_type()) &&
        $cast(ring, value))
      return $sformatf("ring:%0d:%0b", ring.index, ring.wrap);
    if (has_exact_object_type(value, rdma_page_table_layout::get_type()) &&
        $cast(page_layout, value))
      return $sformatf("page:%0d:%016h:%016h:%0b:%016h:%0b",
                       page_layout.mode, page_layout.sd_base.value,
                       page_layout.current_base.value,
                       page_layout.current_valid,
                       page_layout.next_base.value,
                       page_layout.next_valid);
    if (has_exact_object_type(value, rdma_address_vector::get_type()) &&
        $cast(address_vector, value)) begin
      result = $sformatf(
        "av:%0d:%0d:%0d:%0d:%012h:%0b:%0b:%0b:%0b:%0b:%0b:%03h:%02h:%05h:%02h:%04h",
        address_vector.source_address_index, address_vector.source_vport,
        address_vector.destination_vport,
        address_vector.destination_port,
        address_vector.destination_mac, address_vector.ipv6,
        address_vector.vlan_enable, address_vector.cfi,
        address_vector.lag_enable, address_vector.tunnel_enable,
        address_vector.forwarding_enable, address_vector.vlan_id,
        address_vector.traffic_class, address_vector.flow_label,
        address_vector.hop_limit, address_vector.udp_source_port
      );
      foreach (address_vector.destination_ip[i])
        result = {result,
                  $sformatf(":%02h", address_vector.destination_ip[i])};
      return result;
    end
    if (has_exact_object_type(value, rdma_urc_queue_config::get_type()) &&
        $cast(queues, value))
      return $sformatf(
        "urcq:%016h:%016h:%016h:%0d:%0d:%0d:%0d:%0d:%0d",
        queues.rsq_backing.value, queues.rdsq_backing.value,
        queues.dsq_backing.value, queues.rsq_depth, queues.rdsq_depth,
        queues.rdsq_fetch_count, queues.dsq_fetch_count,
        queues.rq_sequence_threshold_entries,
        queues.sq_completion_threshold_entries
      );
    if (has_exact_object_type(value, rdma_mr_page_layout::get_type()) &&
        $cast(mr_page_layout, value))
      return $sformatf(
        "mrpage:%0d:%0d:%016h:%016h:%0d:%0d:%0b:%0b:%0b:%0d:%0d",
        mr_page_layout.pbl_mode, mr_page_layout.host_page_size,
        mr_page_layout.pba0.value, mr_page_layout.pba1.value,
        mr_page_layout.first_pbl_index, mr_page_layout.address_mode,
        mr_page_layout.odp, mr_page_layout.invalidate_enable,
        mr_page_layout.payload_vf_enable,
        mr_page_layout.payload_vf_id, mr_page_layout.mr_serial
      );
    if (has_exact_object_type(value, rdma_qpc_behavior::get_type()) &&
        $cast(behavior, value))
      return $sformatf("behavior:%0d:%0b:%0b:%0b:%0b:%0b:%0d",
                       behavior.transport_version,
                       behavior.migration_enable,
                       behavior.tx_endian_swap, behavior.rx_endian_swap,
                       behavior.read_after_write_fence,
                       behavior.atomic_after_atomic_fence,
                       behavior.\priority );
    if (has_exact_object_type(value, rdma_qpc_rc_ext::get_type()) &&
        $cast(rc_ext, value))
      return $sformatf("rc:%06h:%06h:%06h:%0d:%0d",
                       rc_ext.remote_qpn, rc_ext.send_psn,
                       rc_ext.recv_psn, rc_ext.retry_count,
                       rc_ext.rnr_retry_count);
    if (has_exact_object_type(value, rdma_qpc_ud_ext::get_type()) &&
        $cast(ud_ext, value))
      return $sformatf("ud:%08h", ud_ext.qkey);
    if (has_exact_object_type(value, rdma_qpc_urc_ext::get_type()) &&
        $cast(urc_ext, value))
      return $sformatf("urc:%06h:%06h:%06h:%06h:%06h:%s",
                       urc_ext.remote_qpn, urc_ext.rbsn, urc_ext.dbsn,
                       urc_ext.rpsn, urc_ext.dpsn,
                       nested_value_key(urc_ext.queues));
    return "";
  endfunction

  // 功能：在 rdma_cmq_engine 中，body_value_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：body（输入）；body_value_key 读取 body 并使用字段 value、rdma_cmq_sqe_model、rdma_qpc_model、rdma_cqc_model、rdma_mrt_model、rdma_srqc_model、rdma_ceqc_model、rdma_aeqc_model；函数返回 string，不取得调用方资源所有权。
// 失败/边界：body_value_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function automatic string body_value_key(rdma_hw_model body);
    rdma_cmq_sqe_model sqe;
    rdma_qpc_model qpc;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;

    if (body == null)
      return "<null-body>";
    if (has_exact_object_type(body, rdma_cmq_sqe_model::get_type()) &&
        $cast(sqe, body))
      return $sformatf("sqe:%0d:%016h:%08h:%s:%s:%s", sqe.opcode,
                       sqe.command_id, sqe.flags,
                       handle_value_key(sqe.function_h),
                       handle_value_key(sqe.target_h),
                       (sqe.context_model == null) ? "<null-context>" :
                         body_value_key(sqe.context_model));
    if (has_exact_object_type(body, rdma_qpc_model::get_type()) &&
        $cast(qpc, body))
      return $sformatf(
        "qpc:%s:%s:%s:%s:%s:%0d:%0d:%0d:%0d:%0d:%04h:%02h:%0h:%0d:%0d:%0d:%016h:%016h:%016h:%0d:%0d:%s:%0b:%0b:%0b:%s:%s",
        handle_value_key(qpc.qp_h), handle_value_key(qpc.pd_h),
        handle_value_key(qpc.send_cq_h),
        handle_value_key(qpc.recv_cq_h), handle_value_key(qpc.srq_h),
        qpc.transport, qpc.state, qpc.host_id, qpc.vf_id,
        qpc.stat_index, qpc.pkey, qpc.qp_sequence, qpc.access,
        qpc.path_mtu_bytes, qpc.sq_depth, qpc.rq_depth,
        qpc.sq_backing.value, qpc.rq_backing.value,
        qpc.context_backing.value, qpc.sq_mode, qpc.rq_mode,
        nested_value_key(qpc.address_vector), qpc.signature_enable,
        qpc.tx_flow_control, qpc.rx_flow_control,
        nested_value_key(qpc.behavior),
        nested_value_key(qpc.transport_ext)
      );
    if (has_exact_object_type(body, rdma_cqc_model::get_type()) &&
        $cast(cqc, body))
      return $sformatf(
        "cqc:%s:%s:%0d:%0d:%0d:%0d:%s:%s:%s:%0b:%0b:%0h:%0h:%0h:%016h",
        handle_value_key(cqc.cq_h), handle_value_key(cqc.ceq_h),
        cqc.state, cqc.depth, cqc.cqe_size_bytes, cqc.threshold,
        nested_value_key(cqc.page_layout),
        nested_value_key(cqc.producer), nested_value_key(cqc.consumer),
        cqc.urc_enable, cqc.load_ci_done, cqc.last_arm_sequence,
        cqc.arm_sequence, cqc.arm_state, cqc.shadow_backing.value
      );
    if (has_exact_object_type(body, rdma_mrt_model::get_type()) &&
        $cast(mrt, body))
      return $sformatf(
        "mrt:%s:%s:%0d:%016h:%016h:%08h:%08h:%0h:%0h:%s",
        handle_value_key(mrt.mr_h), handle_value_key(mrt.pd_h),
        mrt.state, mrt.iova.value, mrt.length, mrt.lkey, mrt.rkey,
        mrt.access, mrt.object_type, nested_value_key(mrt.page_layout)
      );
    if (has_exact_object_type(body, rdma_srqc_model::get_type()) &&
        $cast(srqc, body))
      return $sformatf(
        "srqc:%s:%s:%0d:%0d:%0d:%0d:%0d:%016h:%016h:%s:%0h",
        handle_value_key(srqc.srq_h), handle_value_key(srqc.pd_h),
        srqc.state, srqc.depth, srqc.load_pi_threshold,
        srqc.limit_threshold, srqc.object_mode,
        srqc.srfq_backing.value, srqc.shadow_backing.value,
        nested_value_key(srqc.producer), srqc.arm_sequence
      );
    if (has_exact_object_type(body, rdma_ceqc_model::get_type()) &&
        $cast(ceqc, body))
      return $sformatf("ceqc:%s:%0d:%0d:%0d:%s:%s:%s",
                       handle_value_key(ceqc.ceq_h), ceqc.state,
                       ceqc.depth, ceqc.vector_id,
                       nested_value_key(ceqc.page_layout),
                       nested_value_key(ceqc.producer),
                       nested_value_key(ceqc.consumer));
    if (has_exact_object_type(body, rdma_aeqc_model::get_type()) &&
        $cast(aeqc, body))
      return $sformatf("aeqc:%s:%0d:%0d:%0d:%s:%s:%s",
                       handle_value_key(aeqc.aeq_h), aeqc.state,
                       aeqc.depth, aeqc.vector_id,
                       nested_value_key(aeqc.page_layout),
                       nested_value_key(aeqc.producer),
                       nested_value_key(aeqc.consumer));
    return "";
  endfunction

  // 功能：在 rdma_cmq_engine 中由 same_body_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_body_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function automatic bit same_body_value(
    rdma_hw_model lhs,
    rdma_hw_model rhs
  );
    uvm_object_wrapper lhs_type;
    uvm_object_wrapper rhs_type;
    rdma_cmq_sqe_model lhs_sqe;
    rdma_cmq_sqe_model rhs_sqe;
    string lhs_value;
    string rhs_value;

    if (lhs == null || rhs == null)
      return 1'b0;
    lhs_type = lhs.get_object_type();
    rhs_type = rhs.get_object_type();
    if (lhs_type == null || rhs_type == null || lhs_type != rhs_type)
      return 1'b0;
    if (!core_body_shell_is_exact(lhs) ||
        !core_body_shell_is_exact(rhs)) begin
      if (profile == null)
        return 1'b0;
      return profile.same_command_body_value(lhs, rhs);
    end
    if (lhs_type == rdma_cmq_sqe_model::get_type()) begin
      if (!$cast(lhs_sqe, lhs) || !$cast(rhs_sqe, rhs))
        return 1'b0;
      if (lhs_sqe.opcode != rhs_sqe.opcode ||
          lhs_sqe.command_id != rhs_sqe.command_id ||
          lhs_sqe.flags != rhs_sqe.flags ||
          handle_value_key(lhs_sqe.function_h) !=
            handle_value_key(rhs_sqe.function_h) ||
          handle_value_key(lhs_sqe.target_h) !=
            handle_value_key(rhs_sqe.target_h) ||
          ((lhs_sqe.context_model == null) !=
           (rhs_sqe.context_model == null)))
        return 1'b0;
      return lhs_sqe.context_model == null ||
             same_body_value(lhs_sqe.context_model,
                             rhs_sqe.context_model);
    end
    lhs_value = body_value_key(lhs);
    rhs_value = body_value_key(rhs);
    if (lhs_value != "" || rhs_value != "")
      return lhs_value != "" && lhs_value == rhs_value;
    return 1'b0;
  endfunction

  // 功能：在 rdma_cmq_engine 中，append_body_graph_nodes 将输入对象登记或挂接到当前集合/依赖图，并同步维护对应账本和生命周期引用。
  // 输入/输出及副作用：body（输入）、nodes（引用）；append_body_graph_nodes 可能更新本对象明确拥有的状态，并写入 nodes；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：append_body_graph_nodes 无返回值，仅执行 函数体中的顺序操作；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  protected function automatic void append_body_graph_nodes(
    rdma_hw_model body,
    ref uvm_object nodes[$]
  );
    rdma_cmq_sqe_model sqe;
    rdma_qpc_model qpc;
    rdma_qpc_urc_ext urc_ext;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;

    if (body == null)
      return;
    nodes.push_back(body);
    if (has_exact_object_type(body, rdma_cmq_sqe_model::get_type()) &&
        $cast(sqe, body)) begin
      if (sqe.function_h != null) nodes.push_back(sqe.function_h);
      if (sqe.target_h != null) nodes.push_back(sqe.target_h);
    end
    else if (has_exact_object_type(body, rdma_qpc_model::get_type()) &&
             $cast(qpc, body)) begin
      if (qpc.qp_h != null) nodes.push_back(qpc.qp_h);
      if (qpc.pd_h != null) nodes.push_back(qpc.pd_h);
      if (qpc.send_cq_h != null) nodes.push_back(qpc.send_cq_h);
      if (qpc.recv_cq_h != null) nodes.push_back(qpc.recv_cq_h);
      if (qpc.srq_h != null) nodes.push_back(qpc.srq_h);
      if (qpc.address_vector != null) nodes.push_back(qpc.address_vector);
      if (qpc.behavior != null) nodes.push_back(qpc.behavior);
      if (qpc.transport_ext != null) nodes.push_back(qpc.transport_ext);
      if ($cast(urc_ext, qpc.transport_ext) && urc_ext.queues != null)
        nodes.push_back(urc_ext.queues);
    end
    else if (has_exact_object_type(body, rdma_cqc_model::get_type()) &&
             $cast(cqc, body)) begin
      if (cqc.cq_h != null) nodes.push_back(cqc.cq_h);
      if (cqc.ceq_h != null) nodes.push_back(cqc.ceq_h);
      if (cqc.page_layout != null) nodes.push_back(cqc.page_layout);
      if (cqc.producer != null) nodes.push_back(cqc.producer);
      if (cqc.consumer != null) nodes.push_back(cqc.consumer);
    end
    else if (has_exact_object_type(body, rdma_mrt_model::get_type()) &&
             $cast(mrt, body)) begin
      if (mrt.mr_h != null) nodes.push_back(mrt.mr_h);
      if (mrt.pd_h != null) nodes.push_back(mrt.pd_h);
      if (mrt.page_layout != null) nodes.push_back(mrt.page_layout);
    end
    else if (has_exact_object_type(body, rdma_srqc_model::get_type()) &&
             $cast(srqc, body)) begin
      if (srqc.srq_h != null) nodes.push_back(srqc.srq_h);
      if (srqc.pd_h != null) nodes.push_back(srqc.pd_h);
      if (srqc.producer != null) nodes.push_back(srqc.producer);
    end
    else if (has_exact_object_type(body, rdma_ceqc_model::get_type()) &&
             $cast(ceqc, body)) begin
      if (ceqc.ceq_h != null) nodes.push_back(ceqc.ceq_h);
      if (ceqc.page_layout != null) nodes.push_back(ceqc.page_layout);
      if (ceqc.producer != null) nodes.push_back(ceqc.producer);
      if (ceqc.consumer != null) nodes.push_back(ceqc.consumer);
    end
    else if (has_exact_object_type(body, rdma_aeqc_model::get_type()) &&
             $cast(aeqc, body)) begin
      if (aeqc.aeq_h != null) nodes.push_back(aeqc.aeq_h);
      if (aeqc.page_layout != null) nodes.push_back(aeqc.page_layout);
      if (aeqc.producer != null) nodes.push_back(aeqc.producer);
      if (aeqc.consumer != null) nodes.push_back(aeqc.consumer);
    end
  endfunction

  // 功能：在 rdma_cmq_engine 中，body_graph_detached 检查嵌套 body/graph 引用是否已经 detached，防止编码或恢复阶段残留可变别名。
  // 输入/输出及副作用：source（输入）、snapshot（输入）；body_graph_detached 读取 source、snapshot 并使用字段 source_type、snapshot_type；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：body_graph_detached 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function automatic bit body_graph_detached(
    rdma_hw_model source,
    rdma_hw_model snapshot
  );
    uvm_object_wrapper source_type;
    uvm_object_wrapper snapshot_type;
    rdma_cmq_sqe_model source_sqe;
    rdma_cmq_sqe_model snapshot_sqe;
    uvm_object source_nodes[$];
    uvm_object snapshot_nodes[$];

    if (source == null || snapshot == null)
      return 1'b0;
    source_type = source.get_object_type();
    snapshot_type = snapshot.get_object_type();
    if (source_type == null || snapshot_type == null ||
        source_type != snapshot_type)
      return 1'b0;
    if (!core_body_shell_is_exact(source) ||
        !core_body_shell_is_exact(snapshot)) begin
      if (profile == null)
        return 1'b0;
      return profile.command_body_graph_detached(source, snapshot);
    end
    if (source_type == rdma_cmq_sqe_model::get_type()) begin
      if (!$cast(source_sqe, source) || !$cast(snapshot_sqe, snapshot))
        return 1'b0;
      append_body_graph_nodes(source, source_nodes);
      append_body_graph_nodes(snapshot, snapshot_nodes);
      foreach (source_nodes[i])
        foreach (snapshot_nodes[j])
          if (source_nodes[i] == snapshot_nodes[j])
            return 1'b0;
      if ((source_sqe.context_model == null) !=
          (snapshot_sqe.context_model == null))
        return 1'b0;
      return source_sqe.context_model == null ||
             body_graph_detached(source_sqe.context_model,
                                 snapshot_sqe.context_model);
    end
    append_body_graph_nodes(source, source_nodes);
    append_body_graph_nodes(snapshot, snapshot_nodes);
    foreach (source_nodes[i])
      foreach (snapshot_nodes[j])
        if (source_nodes[i] == snapshot_nodes[j])
          return 1'b0;
    return 1'b1;
  endfunction

  // 功能：checked_function_snapshot 复制 source、label、failure_code、snapshot 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）、label（输入）、failure_code（输入）、snapshot（输出）；checked_function_snapshot 读取 source、label、failure_code、snapshot 并使用字段 snapshot、saved_kind、source_type_name、saved_function_uid、saved_object_id、saved_generation、cloned_object、source.kind，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：checked_function_snapshot 先检查 source == null；cloned_object == null || !$cast(snapshot, cloned_object，再返回 snapshot_failure(failure_code, {label, " Function is null"})；rdma_status::success()；拒绝分支不提交部分状态，也不隐式重试。
  protected function rdma_status checked_function_snapshot(
    rdma_function_handle source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_function_handle snapshot
  );
    uvm_object cloned_object;
    string source_type_name;
    rdma_resource_kind_e saved_kind;
    longint unsigned saved_function_uid;
    int unsigned saved_object_id;
    int unsigned saved_generation;

    snapshot = null;
    if (source == null)
      return snapshot_failure(failure_code, {label, " Function is null"});
    saved_kind = source.kind;
    source_type_name = source.get_type_name();
    saved_function_uid = source.function_uid;
    saved_object_id = source.object_id;
    saved_generation = source.generation;
    cloned_object = source.clone();
    source.kind = saved_kind;
    source.function_uid = saved_function_uid;
    source.object_id = saved_object_id;
    source.generation = saved_generation;
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source || snapshot.get_type_name() != source_type_name) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " Function snapshot clone contract failed"}
      );
    end
    if (source.kind != saved_kind ||
        source.function_uid != saved_function_uid ||
        source.object_id != saved_object_id ||
        source.generation != saved_generation ||
        snapshot.kind != saved_kind ||
        snapshot.function_uid != saved_function_uid ||
        snapshot.object_id != saved_object_id ||
        snapshot.generation != saved_generation) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " Function snapshot changed its source value"}
      );
    end
    return rdma_status::success();
  endfunction

  // 功能：checked_handle_snapshot 复制 source、label、failure_code、snapshot 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）、label（输入）、failure_code（输入）、snapshot（输出）；checked_handle_snapshot 读取 source、label、failure_code、snapshot 并使用字段 snapshot、saved_kind、source_type_name、saved_function_uid、saved_object_id、saved_generation、cloned_object、source.kind，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：checked_handle_snapshot 先检查 source == null；cloned_object == null || !$cast(snapshot, cloned_object，再返回 snapshot_failure(failure_code, {label, " handle is null"})；rdma_status::success()；拒绝分支不提交部分状态，也不隐式重试。
  protected function rdma_status checked_handle_snapshot(
    rdma_handle source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_handle snapshot
  );
    uvm_object cloned_object;
    string source_type_name;
    rdma_resource_kind_e saved_kind;
    longint unsigned saved_function_uid;
    int unsigned saved_object_id;
    int unsigned saved_generation;

    snapshot = null;
    if (source == null)
      return snapshot_failure(failure_code, {label, " handle is null"});
    saved_kind = source.kind;
    source_type_name = source.get_type_name();
    saved_function_uid = source.function_uid;
    saved_object_id = source.object_id;
    saved_generation = source.generation;
    cloned_object = source.clone();
    source.kind = saved_kind;
    source.function_uid = saved_function_uid;
    source.object_id = saved_object_id;
    source.generation = saved_generation;
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source || snapshot.get_type_name() != source_type_name) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " handle snapshot clone contract failed"}
      );
    end
    if (source.kind != saved_kind ||
        source.function_uid != saved_function_uid ||
        source.object_id != saved_object_id ||
        source.generation != saved_generation ||
        snapshot.kind != saved_kind ||
        snapshot.function_uid != saved_function_uid ||
        snapshot.object_id != saved_object_id ||
        snapshot.generation != saved_generation) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " handle snapshot changed its source value"}
      );
    end
    return rdma_status::success();
  endfunction

  // 功能：nested_object_status 校验 source、label、failure_code 与当前对象状态的一致性，并显式处理“is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：source（输入）、label（输入）、failure_code（输入）；nested_object_status 读取 source、label、failure_code 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：nested_object_status 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status nested_object_status(
    uvm_object source,
    string label,
    rdma_status_code_e failure_code
  );
    rdma_handle handle;
    rdma_ring_position ring;
    rdma_page_table_layout page_layout;
    rdma_address_vector address_vector;
    rdma_urc_queue_config queues;
    rdma_mr_page_layout mr_page_layout;
    rdma_qpc_behavior behavior;
    rdma_qpc_transport_ext transport_ext;
    rdma_status status;

    if (source == null)
      return snapshot_failure(failure_code, {label, " is null"});
    if ($cast(handle, source))
      return rdma_status::success();
    if ($cast(ring, source))
      status = ring.validate();
    else if ($cast(page_layout, source))
      status = page_layout.validate();
    else if ($cast(address_vector, source))
      status = address_vector.validate();
    else if ($cast(queues, source))
      status = queues.validate();
    else if ($cast(mr_page_layout, source))
      status = mr_page_layout.validate();
    else if ($cast(behavior, source))
      status = behavior.validate();
    else if ($cast(transport_ext, source))
      status = transport_ext.validate();
    else
      return snapshot_failure(
        failure_code, {label, " has an unsupported nested type"}
      );
    if (status == null)
      return snapshot_failure(
        failure_code, {label, " validation returned null"}
      );
    return status;
  endfunction

  // 功能：checked_nested_snapshot 复制 source、label、failure_code、snapshot 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）、label（输入）、failure_code（输入）、snapshot（输出）；checked_nested_snapshot 读取 source、label、failure_code、snapshot 并使用字段 snapshot、status、source_type_name、saved_value、source_wrapper、saved_source、cloned_object，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：checked_nested_snapshot 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status checked_nested_snapshot(
    uvm_object source,
    string label,
    rdma_status_code_e failure_code,
    output uvm_object snapshot
  );
    uvm_object cloned_object;
    uvm_object saved_source;
    uvm_object_wrapper source_wrapper;
    rdma_status status;
    string source_type_name;
    string saved_value;

    snapshot = null;
    status = nested_object_status(source, label, failure_code);
    if (!status.ok())
      return status;
    source_type_name = source.get_type_name();
    saved_value = nested_value_key(source);
    if (saved_value == "")
      return snapshot_failure(
        failure_code, {label, " has no checked value representation"}
      );
    source_wrapper = source.get_object_type();
    saved_source = (source_wrapper == null) ? null :
      source_wrapper.create_object({label, "_saved"});
    if (saved_source == null)
      return snapshot_failure(
        failure_code, {label, " source value capture failed"}
      );
    saved_source.copy(source);
    cloned_object = source.clone();
    source.copy(saved_source);
    if (cloned_object == null || cloned_object == source ||
        cloned_object.get_type_name() != source_type_name) begin
      return snapshot_failure(
        failure_code, {label, " snapshot clone contract failed"}
      );
    end
    if (nested_value_key(source) != saved_value ||
        nested_value_key(cloned_object) != saved_value) begin
      return snapshot_failure(
        failure_code, {label, " snapshot changed its source value"}
      );
    end
    status = nested_object_status(cloned_object, label, failure_code);
    if (!status.ok())
      return status;
    snapshot = cloned_object;
    return rdma_status::success();
  endfunction

  // 功能：checked_transport_snapshot 复制 source、label、failure_code、snapshot 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）、label（输入）、failure_code（输入）、snapshot（输出）；checked_transport_snapshot 读取 source、label、failure_code、snapshot 并使用字段 snapshot、status、source_type_name、saved_value、saved_queues、source_urc.queues、source_wrapper、saved_object，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：checked_transport_snapshot 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status checked_transport_snapshot(
    rdma_qpc_transport_ext source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_qpc_transport_ext snapshot
  );
    uvm_object cloned_object;
    uvm_object queues_object;
    uvm_object saved_object;
    uvm_object_wrapper source_wrapper;
    rdma_status status;
    rdma_qpc_rc_ext source_rc;
    rdma_qpc_ud_ext source_ud;
    rdma_qpc_urc_ext source_urc;
    rdma_qpc_urc_ext snapshot_urc;
    rdma_urc_queue_config queues_snapshot;
    string source_type_name;
    string saved_value;
    string saved_shell_value;
    rdma_urc_queue_config saved_queues;

    snapshot = null;
    if (source == null)
      return snapshot_failure(failure_code,
                              {label, " transport extension is null"});
    if ($cast(source_rc, source) || $cast(source_ud, source)) begin
      status = checked_nested_snapshot(
        source, {label, " transport extension"}, failure_code,
        cloned_object
      );
      if (!status.ok())
        return status;
      if (!$cast(snapshot, cloned_object))
        return snapshot_failure(
          failure_code, {label, " transport snapshot type is invalid"}
        );
      return rdma_status::success();
    end
    if (!$cast(source_urc, source))
      return snapshot_failure(
        failure_code, {label, " transport extension type is unsupported"}
      );
    status = nested_object_status(source_urc, label, failure_code);
    if (!status.ok())
      return status;
    status = checked_nested_snapshot(
      source_urc.queues, {label, " URC queues"}, failure_code,
      queues_object
    );
    if (!status.ok())
      return status;
    if (!$cast(queues_snapshot, queues_object))
      return snapshot_failure(failure_code,
                              {label, " URC queue snapshot is invalid"});
    source_type_name = source.get_type_name();
    saved_value = nested_value_key(source);
    saved_queues = source_urc.queues;
    source_urc.queues = null;
    source_wrapper = source.get_object_type();
    saved_object = (source_wrapper == null) ? null :
      source_wrapper.create_object({label, "_saved_transport"});
    if (saved_object == null) begin
      source_urc.queues = saved_queues;
      return snapshot_failure(
        failure_code, {label, " transport value capture failed"}
      );
    end
    saved_object.copy(source);
    saved_shell_value = nested_value_key(saved_object);
    cloned_object = source.clone();
    source.copy(saved_object);
    source_urc.queues = saved_queues;
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source || snapshot.get_type_name() != source_type_name ||
        !$cast(snapshot_urc, snapshot)) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " transport snapshot clone contract failed"}
      );
    end
    if (nested_value_key(source) != saved_value ||
        nested_value_key(snapshot) != saved_shell_value ||
        snapshot_urc.queues != null) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " transport snapshot changed its source value"}
      );
    end
    snapshot_urc.queues = queues_snapshot;
    if (snapshot_urc.queues == source_urc.queues) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " transport snapshot aliases its source"}
      );
    end
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " transport validation returned null"}
      );
    end
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  // 功能：在 rdma_cmq_engine 中，clear_body_references 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：body（输入）、references（输入）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_body_references 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  protected function automatic bit clear_body_references(
    rdma_hw_model body,
    ref uvm_object references[$]
  );
    rdma_cmq_sqe_model sqe;
    rdma_qpc_model qpc;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;

    references.delete();
    if ($cast(sqe, body)) begin
      references.push_back(sqe.function_h);
      references.push_back(sqe.target_h);
      references.push_back(sqe.context_model);
      sqe.function_h = null;
      sqe.target_h = null;
      sqe.context_model = null;
      return 1'b1;
    end
    if ($cast(qpc, body)) begin
      references.push_back(qpc.qp_h);
      references.push_back(qpc.pd_h);
      references.push_back(qpc.send_cq_h);
      references.push_back(qpc.recv_cq_h);
      references.push_back(qpc.srq_h);
      references.push_back(qpc.address_vector);
      references.push_back(qpc.behavior);
      references.push_back(qpc.transport_ext);
      qpc.qp_h = null;
      qpc.pd_h = null;
      qpc.send_cq_h = null;
      qpc.recv_cq_h = null;
      qpc.srq_h = null;
      qpc.address_vector = null;
      qpc.behavior = null;
      qpc.transport_ext = null;
      return 1'b1;
    end
    if ($cast(cqc, body)) begin
      references.push_back(cqc.cq_h);
      references.push_back(cqc.ceq_h);
      references.push_back(cqc.page_layout);
      references.push_back(cqc.producer);
      references.push_back(cqc.consumer);
      cqc.cq_h = null;
      cqc.ceq_h = null;
      cqc.page_layout = null;
      cqc.producer = null;
      cqc.consumer = null;
      return 1'b1;
    end
    if ($cast(mrt, body)) begin
      references.push_back(mrt.mr_h);
      references.push_back(mrt.pd_h);
      references.push_back(mrt.page_layout);
      mrt.mr_h = null;
      mrt.pd_h = null;
      mrt.page_layout = null;
      return 1'b1;
    end
    if ($cast(srqc, body)) begin
      references.push_back(srqc.srq_h);
      references.push_back(srqc.pd_h);
      references.push_back(srqc.producer);
      srqc.srq_h = null;
      srqc.pd_h = null;
      srqc.producer = null;
      return 1'b1;
    end
    if ($cast(ceqc, body)) begin
      references.push_back(ceqc.ceq_h);
      references.push_back(ceqc.page_layout);
      references.push_back(ceqc.producer);
      references.push_back(ceqc.consumer);
      ceqc.ceq_h = null;
      ceqc.page_layout = null;
      ceqc.producer = null;
      ceqc.consumer = null;
      return 1'b1;
    end
    if ($cast(aeqc, body)) begin
      references.push_back(aeqc.aeq_h);
      references.push_back(aeqc.page_layout);
      references.push_back(aeqc.producer);
      references.push_back(aeqc.consumer);
      aeqc.aeq_h = null;
      aeqc.page_layout = null;
      aeqc.producer = null;
      aeqc.consumer = null;
      return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：执行 restore_body_references 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：body（输入）、references（输入）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：restore_body_references 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  protected function automatic bit restore_body_references(
    rdma_hw_model body,
    ref uvm_object references[$]
  );
    rdma_cmq_sqe_model sqe;
    rdma_qpc_model qpc;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;

    if ($cast(sqe, body) && references.size() == 3) begin
      if (!$cast(sqe.function_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(sqe.target_h, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(sqe.context_model, references[2]) &&
          references[2] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(qpc, body) && references.size() == 8) begin
      if (!$cast(qpc.qp_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(qpc.pd_h, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(qpc.send_cq_h, references[2]) && references[2] != null)
        return 1'b0;
      if (!$cast(qpc.recv_cq_h, references[3]) && references[3] != null)
        return 1'b0;
      if (!$cast(qpc.srq_h, references[4]) && references[4] != null)
        return 1'b0;
      if (!$cast(qpc.address_vector, references[5]) &&
          references[5] != null)
        return 1'b0;
      if (!$cast(qpc.behavior, references[6]) && references[6] != null)
        return 1'b0;
      if (!$cast(qpc.transport_ext, references[7]) &&
          references[7] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(cqc, body) && references.size() == 5) begin
      if (!$cast(cqc.cq_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(cqc.ceq_h, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(cqc.page_layout, references[2]) && references[2] != null)
        return 1'b0;
      if (!$cast(cqc.producer, references[3]) && references[3] != null)
        return 1'b0;
      if (!$cast(cqc.consumer, references[4]) && references[4] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(mrt, body) && references.size() == 3) begin
      if (!$cast(mrt.mr_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(mrt.pd_h, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(mrt.page_layout, references[2]) && references[2] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(srqc, body) && references.size() == 3) begin
      if (!$cast(srqc.srq_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(srqc.pd_h, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(srqc.producer, references[2]) && references[2] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(ceqc, body) && references.size() == 4) begin
      if (!$cast(ceqc.ceq_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(ceqc.page_layout, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(ceqc.producer, references[2]) && references[2] != null)
        return 1'b0;
      if (!$cast(ceqc.consumer, references[3]) && references[3] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(aeqc, body) && references.size() == 4) begin
      if (!$cast(aeqc.aeq_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(aeqc.page_layout, references[1]) && references[1] != null)
        return 1'b0;
      if (!$cast(aeqc.producer, references[2]) && references[2] != null)
        return 1'b0;
      if (!$cast(aeqc.consumer, references[3]) && references[3] != null)
        return 1'b0;
      return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：在 rdma_cmq_engine 中，body_references_are_null 检查嵌套 body/graph 引用是否已经 detached，防止编码或恢复阶段残留可变别名。
  // 输入/输出及副作用：body（输入）；body_references_are_null 读取 body 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：body_references_are_null 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function automatic bit body_references_are_null(
    rdma_hw_model body
  );
    rdma_cmq_sqe_model sqe;
    rdma_qpc_model qpc;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;

    if ($cast(sqe, body))
      return sqe.function_h == null && sqe.target_h == null &&
             sqe.context_model == null;
    if ($cast(qpc, body))
      return qpc.qp_h == null && qpc.pd_h == null &&
             qpc.send_cq_h == null && qpc.recv_cq_h == null &&
             qpc.srq_h == null && qpc.address_vector == null &&
             qpc.behavior == null && qpc.transport_ext == null;
    if ($cast(cqc, body))
      return cqc.cq_h == null && cqc.ceq_h == null &&
             cqc.page_layout == null && cqc.producer == null &&
             cqc.consumer == null;
    if ($cast(mrt, body))
      return mrt.mr_h == null && mrt.pd_h == null &&
             mrt.page_layout == null;
    if ($cast(srqc, body))
      return srqc.srq_h == null && srqc.pd_h == null &&
             srqc.producer == null;
    if ($cast(ceqc, body))
      return ceqc.ceq_h == null && ceqc.page_layout == null &&
             ceqc.producer == null && ceqc.consumer == null;
    if ($cast(aeqc, body))
      return aeqc.aeq_h == null && aeqc.page_layout == null &&
             aeqc.producer == null && aeqc.consumer == null;
    return 1'b0;
  endfunction

  // 功能：checked_outer_body_clone 复制 source、saved_value、label、failure_code、snapshot 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）、saved_value（输入）、label（输入）、failure_code（输入）、snapshot（输出）；checked_outer_body_clone 读取 source、saved_value、label、failure_code、snapshot 并使用字段 snapshot、source_type_name、source_wrapper、saved_object、saved_shell_value、cloned_object，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：checked_outer_body_clone 先检查 !clear_body_references(source, saved_references；saved_object == null || !$cast(saved_body, saved_object；!restore_body_references(source, saved_references，再返回 rdma_status::success()；拒绝分支不提交部分状态，也不隐式重试。
  protected function rdma_status checked_outer_body_clone(
    rdma_hw_model source,
    string saved_value,
    string label,
    rdma_status_code_e failure_code,
    output rdma_hw_model snapshot
  );
    uvm_object cloned_object;
    uvm_object saved_object;
    uvm_object_wrapper source_wrapper;
    rdma_status status;
    rdma_hw_model saved_body;
    string source_type_name;
    string saved_shell_value;
    uvm_object saved_references[$];

    snapshot = null;
    source_type_name = source.get_type_name();
    if (!clear_body_references(source, saved_references))
      return snapshot_failure(
        failure_code, {label, " body reference capture failed"}
      );
    source_wrapper = source.get_object_type();
    saved_object = (source_wrapper == null) ? null :
      source_wrapper.create_object({label, "_saved_shell"});
    if (saved_object == null || !$cast(saved_body, saved_object)) begin
      void'(restore_body_references(source, saved_references));
      return snapshot_failure(
        failure_code, {label, " body value capture failed"}
      );
    end
    saved_body.copy(source);
    saved_shell_value = body_value_key(saved_body);
    cloned_object = source.clone();
    source.copy(saved_body);
    if (!restore_body_references(source, saved_references)) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " body source restoration failed"}
      );
    end
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source || snapshot.get_type_name() != source_type_name) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " body snapshot clone contract failed"}
      );
    end
    if (body_value_key(source) != saved_value ||
        body_value_key(snapshot) != saved_shell_value ||
        !body_references_are_null(snapshot)) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " body snapshot changed its source value"}
      );
    end
    return rdma_status::success();
  endfunction

  // 功能：checked_qpc_snapshot 复制 source、label、failure_code、snapshot 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）、label（输入）、failure_code（输入）、snapshot（输出）；checked_qpc_snapshot 读取 source、label、failure_code、snapshot 并使用字段 snapshot、saved_value、status、srq_snapshot、cloned_qpc.qp_h、cloned_qpc.pd_h、cloned_qpc.send_cq_h、cloned_qpc.recv_cq_h，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：checked_qpc_snapshot 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status checked_qpc_snapshot(
    rdma_qpc_model source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_hw_model snapshot
  );
    uvm_object nested_snapshot;
    rdma_status status;
    rdma_hw_model cloned_body;
    rdma_qpc_model cloned_qpc;
    rdma_handle qp_snapshot;
    rdma_handle pd_snapshot;
    rdma_handle send_cq_snapshot;
    rdma_handle recv_cq_snapshot;
    rdma_handle srq_snapshot;
    rdma_address_vector address_snapshot;
    rdma_qpc_behavior behavior_snapshot;
    rdma_qpc_transport_ext transport_snapshot;
    string saved_value;

    snapshot = null;
    saved_value = body_value_key(source);
    status = checked_handle_snapshot(source.qp_h, {label, " QPC QP"},
                                     failure_code, qp_snapshot);
    if (!status.ok()) return status;
    status = checked_handle_snapshot(source.pd_h, {label, " QPC PD"},
                                     failure_code, pd_snapshot);
    if (!status.ok()) return status;
    status = checked_handle_snapshot(
      source.send_cq_h, {label, " QPC send CQ"}, failure_code,
      send_cq_snapshot
    );
    if (!status.ok()) return status;
    status = checked_handle_snapshot(
      source.recv_cq_h, {label, " QPC receive CQ"}, failure_code,
      recv_cq_snapshot
    );
    if (!status.ok()) return status;
    srq_snapshot = null;
    if (source.srq_h != null) begin
      status = checked_handle_snapshot(source.srq_h, {label, " QPC SRQ"},
                                       failure_code, srq_snapshot);
      if (!status.ok()) return status;
    end
    status = checked_nested_snapshot(
      source.address_vector, {label, " QPC address vector"}, failure_code,
      nested_snapshot
    );
    if (!status.ok() || !$cast(address_snapshot, nested_snapshot))
      return status.ok() ? snapshot_failure(
        failure_code, {label, " QPC address snapshot is invalid"}
      ) : status;
    status = checked_nested_snapshot(
      source.behavior, {label, " QPC behavior"}, failure_code,
      nested_snapshot
    );
    if (!status.ok() || !$cast(behavior_snapshot, nested_snapshot))
      return status.ok() ? snapshot_failure(
        failure_code, {label, " QPC behavior snapshot is invalid"}
      ) : status;
    status = checked_transport_snapshot(
      source.transport_ext, label, failure_code, transport_snapshot
    );
    if (!status.ok()) return status;
    status = checked_outer_body_clone(
      source, saved_value, label, failure_code, cloned_body
    );
    if (!status.ok()) return status;
    if (!$cast(cloned_qpc, cloned_body))
      return snapshot_failure(failure_code,
                              {label, " QPC body snapshot is invalid"});
    cloned_qpc.qp_h = qp_snapshot;
    cloned_qpc.pd_h = pd_snapshot;
    cloned_qpc.send_cq_h = send_cq_snapshot;
    cloned_qpc.recv_cq_h = recv_cq_snapshot;
    cloned_qpc.srq_h = srq_snapshot;
    cloned_qpc.address_vector = address_snapshot;
    cloned_qpc.behavior = behavior_snapshot;
    cloned_qpc.transport_ext = transport_snapshot;
    snapshot = cloned_qpc;
    if (!body_graph_detached(source, snapshot)) begin
      snapshot = null;
      return snapshot_failure(failure_code,
                              {label, " QPC snapshot aliases its source"});
    end
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return snapshot_failure(failure_code,
                              {label, " QPC validation returned null"});
    end
    if (!status.ok()) snapshot = null;
    return status;
  endfunction

  // 功能：checked_context_snapshot 复制 source、label、failure_code、snapshot 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）、label（输入）、failure_code（输入）、snapshot（输出）；checked_context_snapshot 读取 source、label、failure_code、snapshot 并使用字段 snapshot、handle0_snapshot、handle1_snapshot、nested0_snapshot、nested1_snapshot、nested2_snapshot、saved_value、status，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：checked_context_snapshot 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status checked_context_snapshot(
    rdma_hw_model source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_hw_model snapshot
  );
    rdma_status status;
    rdma_hw_model cloned_body;
    rdma_handle handle0_snapshot;
    rdma_handle handle1_snapshot;
    uvm_object nested0_snapshot;
    uvm_object nested1_snapshot;
    uvm_object nested2_snapshot;
    rdma_page_table_layout page_snapshot;
    rdma_mr_page_layout mr_page_snapshot;
    rdma_ring_position ring0_snapshot;
    rdma_ring_position ring1_snapshot;
    rdma_cqc_model source_cqc;
    rdma_cqc_model cloned_cqc;
    rdma_mrt_model source_mrt;
    rdma_mrt_model cloned_mrt;
    rdma_srqc_model source_srqc;
    rdma_srqc_model cloned_srqc;
    rdma_ceqc_model source_ceqc;
    rdma_ceqc_model cloned_ceqc;
    rdma_aeqc_model source_aeqc;
    rdma_aeqc_model cloned_aeqc;
    string saved_value;

    snapshot = null;
    handle0_snapshot = null;
    handle1_snapshot = null;
    nested0_snapshot = null;
    nested1_snapshot = null;
    nested2_snapshot = null;
    saved_value = body_value_key(source);
    if ($cast(source_cqc, source)) begin
      status = checked_handle_snapshot(source_cqc.cq_h,
                                       {label, " CQC CQ"}, failure_code,
                                       handle0_snapshot);
      if (!status.ok()) return status;
      if (source_cqc.ceq_h != null) begin
        status = checked_handle_snapshot(source_cqc.ceq_h,
                                         {label, " CQC CEQ"}, failure_code,
                                         handle1_snapshot);
        if (!status.ok()) return status;
      end
      status = checked_nested_snapshot(source_cqc.page_layout,
                                       {label, " CQC page layout"},
                                       failure_code, nested0_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_cqc.producer,
                                       {label, " CQC producer"},
                                       failure_code, nested1_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_cqc.consumer,
                                       {label, " CQC consumer"},
                                       failure_code, nested2_snapshot);
      if (!status.ok()) return status;
    end
    else if ($cast(source_mrt, source)) begin
      status = checked_handle_snapshot(source_mrt.mr_h,
                                       {label, " MRT MR"}, failure_code,
                                       handle0_snapshot);
      if (!status.ok()) return status;
      status = checked_handle_snapshot(source_mrt.pd_h,
                                       {label, " MRT PD"}, failure_code,
                                       handle1_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_mrt.page_layout,
                                       {label, " MRT page layout"},
                                       failure_code, nested0_snapshot);
      if (!status.ok()) return status;
    end
    else if ($cast(source_srqc, source)) begin
      status = checked_handle_snapshot(source_srqc.srq_h,
                                       {label, " SRQC SRQ"}, failure_code,
                                       handle0_snapshot);
      if (!status.ok()) return status;
      status = checked_handle_snapshot(source_srqc.pd_h,
                                       {label, " SRQC PD"}, failure_code,
                                       handle1_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_srqc.producer,
                                       {label, " SRQC producer"},
                                       failure_code, nested0_snapshot);
      if (!status.ok()) return status;
    end
    else if ($cast(source_ceqc, source)) begin
      status = checked_handle_snapshot(source_ceqc.ceq_h,
                                       {label, " CEQC CEQ"}, failure_code,
                                       handle0_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_ceqc.page_layout,
                                       {label, " CEQC page layout"},
                                       failure_code, nested0_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_ceqc.producer,
                                       {label, " CEQC producer"},
                                       failure_code, nested1_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_ceqc.consumer,
                                       {label, " CEQC consumer"},
                                       failure_code, nested2_snapshot);
      if (!status.ok()) return status;
    end
    else if ($cast(source_aeqc, source)) begin
      status = checked_handle_snapshot(source_aeqc.aeq_h,
                                       {label, " AEQC AEQ"}, failure_code,
                                       handle0_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_aeqc.page_layout,
                                       {label, " AEQC page layout"},
                                       failure_code, nested0_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_aeqc.producer,
                                       {label, " AEQC producer"},
                                       failure_code, nested1_snapshot);
      if (!status.ok()) return status;
      status = checked_nested_snapshot(source_aeqc.consumer,
                                       {label, " AEQC consumer"},
                                       failure_code, nested2_snapshot);
      if (!status.ok()) return status;
    end
    else begin
      return snapshot_failure(failure_code,
                              {label, " context type is unsupported"});
    end
    status = checked_outer_body_clone(source, saved_value, label,
                                      failure_code, cloned_body);
    if (!status.ok()) return status;
    if (source_cqc != null) begin
      if (!$cast(cloned_cqc, cloned_body) ||
          !$cast(page_snapshot, nested0_snapshot) ||
          !$cast(ring0_snapshot, nested1_snapshot) ||
          !$cast(ring1_snapshot, nested2_snapshot))
        return snapshot_failure(failure_code,
                                {label, " CQC snapshot type is invalid"});
      cloned_cqc.cq_h = handle0_snapshot;
      cloned_cqc.ceq_h = handle1_snapshot;
      cloned_cqc.page_layout = page_snapshot;
      cloned_cqc.producer = ring0_snapshot;
      cloned_cqc.consumer = ring1_snapshot;
    end
    else if (source_mrt != null) begin
      if (!$cast(cloned_mrt, cloned_body) ||
          !$cast(mr_page_snapshot, nested0_snapshot))
        return snapshot_failure(failure_code,
                                {label, " MRT snapshot type is invalid"});
      cloned_mrt.mr_h = handle0_snapshot;
      cloned_mrt.pd_h = handle1_snapshot;
      cloned_mrt.page_layout = mr_page_snapshot;
    end
    else if (source_srqc != null) begin
      if (!$cast(cloned_srqc, cloned_body) ||
          !$cast(ring0_snapshot, nested0_snapshot))
        return snapshot_failure(failure_code,
                                {label, " SRQC snapshot type is invalid"});
      cloned_srqc.srq_h = handle0_snapshot;
      cloned_srqc.pd_h = handle1_snapshot;
      cloned_srqc.producer = ring0_snapshot;
    end
    else if (source_ceqc != null) begin
      if (!$cast(cloned_ceqc, cloned_body) ||
          !$cast(page_snapshot, nested0_snapshot) ||
          !$cast(ring0_snapshot, nested1_snapshot) ||
          !$cast(ring1_snapshot, nested2_snapshot))
        return snapshot_failure(failure_code,
                                {label, " CEQC snapshot type is invalid"});
      cloned_ceqc.ceq_h = handle0_snapshot;
      cloned_ceqc.page_layout = page_snapshot;
      cloned_ceqc.producer = ring0_snapshot;
      cloned_ceqc.consumer = ring1_snapshot;
    end
    else begin
      if (!$cast(cloned_aeqc, cloned_body) ||
          !$cast(page_snapshot, nested0_snapshot) ||
          !$cast(ring0_snapshot, nested1_snapshot) ||
          !$cast(ring1_snapshot, nested2_snapshot))
        return snapshot_failure(failure_code,
                                {label, " AEQC snapshot type is invalid"});
      cloned_aeqc.aeq_h = handle0_snapshot;
      cloned_aeqc.page_layout = page_snapshot;
      cloned_aeqc.producer = ring0_snapshot;
      cloned_aeqc.consumer = ring1_snapshot;
    end
    snapshot = cloned_body;
    if (!body_graph_detached(source, snapshot)) begin
      snapshot = null;
      return snapshot_failure(failure_code,
                              {label, " context snapshot aliases its source"});
    end
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return snapshot_failure(failure_code,
                              {label, " context validation returned null"});
    end
    if (!status.ok()) snapshot = null;
    return status;
  endfunction

  // 功能：checked_opcode_snapshot 复制 source、label、failure_code、snapshot 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）、label（输入）、failure_code（输入）、snapshot（输出）；checked_opcode_snapshot 读取 source、label、failure_code、snapshot 并使用字段 snapshot、status、saved_profile_name、saved_opcode、saved_variant、cloned_object、source.profile_name、source.opcode，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：checked_opcode_snapshot 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status checked_opcode_snapshot(
    rdma_cmq_opcode_key source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_cmq_opcode_key snapshot
  );
    rdma_status status;
    uvm_object cloned_object;
    string saved_profile_name;
    bit [31:0] saved_opcode;
    string saved_variant;

    snapshot = null;
    if (source == null)
      return snapshot_failure(failure_code, {label, " opcode key is null"});
    status = source.validate();
    if (status == null)
      return snapshot_failure(
        failure_code, {label, " opcode validation returned null"}
      );
    if (!status.ok())
      return status;
    saved_profile_name = source.profile_name;
    saved_opcode = source.opcode;
    saved_variant = source.variant;
    cloned_object = source.clone();
    source.profile_name = saved_profile_name;
    source.opcode = saved_opcode;
    source.variant = saved_variant;
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " opcode snapshot clone contract failed"}
      );
    end
    if (source.profile_name != saved_profile_name ||
        source.opcode != saved_opcode || source.variant != saved_variant ||
        snapshot.profile_name != saved_profile_name ||
        snapshot.opcode != saved_opcode ||
        snapshot.variant != saved_variant) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " opcode snapshot changed its source value"}
      );
    end
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " opcode snapshot validation returned null"}
      );
    end
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  // 功能：checked_profile_body_snapshot 复制 source、label、snapshot、staging_invariant_failed 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）、label（输入）、snapshot（输出）、staging_invariant_failed（输出）；checked_profile_body_snapshot 读取 source、label、snapshot、staging_invariant_failed 并使用字段 snapshot、source_type、status、staging_invariant_failed、snapshot_type，并写入 snapshot、staging_invariant_failed；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：checked_profile_body_snapshot 返回 RDMA_SC_INVALID_STATE、RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status checked_profile_body_snapshot(
    rdma_hw_model source,
    string label,
    output rdma_hw_model snapshot,
    output bit staging_invariant_failed
  );
    uvm_object_wrapper source_type;
    uvm_object_wrapper snapshot_type;
    rdma_status status;

    snapshot = null;
    if (profile == null)
      return invalid_argument({label, " body profile is unavailable"});
    source_type = source.get_object_type();
    if (source_type == null)
      return invalid_argument({label, " body dynamic type is unregistered"});
    status = profile.snapshot_command_body(source, snapshot);
    if (status == null) begin
      snapshot = null;
      staging_invariant_failed = 1'b1;
      return snapshot_failure(
        RDMA_SC_INVALID_STATE,
        {label, " body profile snapshot returned null status"}
      );
    end
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    snapshot_type = (snapshot == null) ? null : snapshot.get_object_type();
    if (snapshot == null || snapshot == source || snapshot_type == null ||
        snapshot_type != source_type ||
        !profile.same_command_body_value(source, snapshot) ||
        !profile.command_body_graph_detached(source, snapshot)) begin
      snapshot = null;
      staging_invariant_failed = 1'b1;
      return snapshot_failure(
        RDMA_SC_INVALID_STATE,
        {label, " body profile snapshot contract failed"}
      );
    end
    status = snapshot.validate();
    if (status == null || !status.ok()) begin
      snapshot = null;
      staging_invariant_failed = 1'b1;
      return snapshot_failure(
        RDMA_SC_INVALID_STATE,
        {label, " body profile snapshot validation failed"}
      );
    end
    return rdma_status::success();
  endfunction

  // 功能：checked_body_snapshot 复制 source、label、failure_code、snapshot、staging_invariant_failed 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）、label（输入）、failure_code（输入）、snapshot（输出）、staging_invariant_failed（输出）；checked_body_snapshot 读取 source、label、failure_code、snapshot、staging_invariant_failed 并使用字段 snapshot、staging_invariant_failed、status、saved_body_value、saved_opcode、saved_command_id、saved_flags、target_snapshot，并写入 snapshot、staging_invariant_failed；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：checked_body_snapshot 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status checked_body_snapshot(
    rdma_hw_model source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_hw_model snapshot,
    output bit staging_invariant_failed
  );
    rdma_status status;
    rdma_hw_model cloned_body;
    rdma_cmq_sqe_model source_sqe;
    rdma_cmq_sqe_model cloned_sqe;
    rdma_qpc_model source_qpc;
    rdma_cqc_model source_cqc;
    rdma_mrt_model source_mrt;
    rdma_srqc_model source_srqc;
    rdma_ceqc_model source_ceqc;
    rdma_aeqc_model source_aeqc;
    rdma_function_handle function_snapshot;
    rdma_handle target_snapshot;
    rdma_hw_model context_snapshot;
    rdma_cmq_opcode_e saved_opcode;
    longint unsigned saved_command_id;
    int unsigned saved_flags;
    string saved_body_value;

    snapshot = null;
    staging_invariant_failed = 1'b0;
    if (source == null)
      return snapshot_failure(failure_code, {label, " body is null"});
    status = source.validate();
    if (status == null)
      return snapshot_failure(
        failure_code, {label, " body validation returned null"}
      );
    if (!status.ok())
      return status;
    if (!core_body_shell_is_exact(source))
      return checked_profile_body_snapshot(
        source, label, snapshot, staging_invariant_failed
      );
    if (!has_exact_object_type(source,
                               rdma_cmq_sqe_model::get_type())) begin
      if (has_exact_object_type(source, rdma_qpc_model::get_type()) &&
          $cast(source_qpc, source))
        return checked_qpc_snapshot(
          source_qpc, label, failure_code, snapshot
        );
      if ((has_exact_object_type(source, rdma_cqc_model::get_type()) &&
           $cast(source_cqc, source)) ||
          (has_exact_object_type(source, rdma_mrt_model::get_type()) &&
           $cast(source_mrt, source)) ||
          (has_exact_object_type(source, rdma_srqc_model::get_type()) &&
           $cast(source_srqc, source)) ||
          (has_exact_object_type(source, rdma_ceqc_model::get_type()) &&
           $cast(source_ceqc, source)) ||
          (has_exact_object_type(source, rdma_aeqc_model::get_type()) &&
           $cast(source_aeqc, source)))
        return checked_context_snapshot(
          source, label, failure_code, snapshot
        );
      return invalid_argument({label, " body exact type is unsupported"});
    end
    if (!$cast(source_sqe, source))
      return invalid_argument({label, " SQE body dynamic type is invalid"});
    begin
      saved_body_value = body_value_key(source);
      saved_opcode = source_sqe.opcode;
      saved_command_id = source_sqe.command_id;
      saved_flags = source_sqe.flags;
      status = checked_function_snapshot(
        source_sqe.function_h, {label, " body"}, failure_code,
        function_snapshot
      );
      if (!status.ok())
        return status;
      target_snapshot = null;
      if (source_sqe.target_h != null) begin
        status = checked_handle_snapshot(
          source_sqe.target_h, {label, " body target"}, failure_code,
          target_snapshot
        );
        if (!status.ok())
          return status;
      end
      context_snapshot = null;
      if (source_sqe.context_model != null) begin
        status = checked_body_snapshot(
          source_sqe.context_model, {label, " body context"}, failure_code,
          context_snapshot, staging_invariant_failed
        );
        if (!status.ok())
          return status;
      end
    end
    status = checked_outer_body_clone(
      source, saved_body_value, label, failure_code, cloned_body
    );
    if (!status.ok())
      return status;
    if (!$cast(cloned_sqe, cloned_body))
      return snapshot_failure(
        failure_code, {label, " body snapshot type is invalid"}
      );
    if (source_sqe.opcode != saved_opcode ||
        source_sqe.command_id != saved_command_id ||
        source_sqe.flags != saved_flags) begin
      return snapshot_failure(
        failure_code, {label, " body snapshot changed its source value"}
      );
    end
    cloned_sqe.function_h = function_snapshot;
    cloned_sqe.target_h = target_snapshot;
    cloned_sqe.context_model = context_snapshot;
    snapshot = cloned_sqe;
    if (!body_graph_detached(source, snapshot)) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " body snapshot aliases its source"}
      );
    end
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " body snapshot validation returned null"}
      );
    end
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  // 功能：checked_image_snapshot 对 image 执行 factory-backed clone 并验证
  //   全部 byte/metadata/target 投影等值且不自别名。
  // 输入/输出及副作用：source/label/failure_code 为只读输入；
  //   snapshot 先清空，成功时保留 source 的 registered runtime type 并恢复
  //   clone 可能改写的公开字段，不接管 source 所有权。
  // 失败/边界：null source、factory 构造失败、clone 返回 null/self
  //   或任一公开字段漂移时按 failure_code 拒绝；不发布 partial snapshot。
  protected function rdma_status checked_image_snapshot(
    rdma_hw_image source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_hw_image snapshot
  );
    uvm_object cloned_object;
    rdma_hw_image saved_value;

    snapshot = null;
    if (source == null)
      return snapshot_failure(failure_code, {label, " image is null"});
    saved_value = rdma_hw_image::type_id::create({label, "_saved"});
    if (saved_value == null)
      return snapshot_failure(
        failure_code, {label, " image value capture failed"}
      );
    saved_value.bytes = source.bytes;
    saved_value.length = source.length;
    saved_value.alignment = source.alignment;
    saved_value.endian = source.endian;
    saved_value.image_kind = source.image_kind;
    saved_value.hardware_version = source.hardware_version;
    saved_value.function_generation = source.function_generation;
    saved_value.write_target_kind = source.write_target_kind;
    saved_value.backing_target = source.backing_target;
    saved_value.hmc_target = source.hmc_target;
    saved_value.bar_target = source.bar_target;
    saved_value.field_summary = source.field_summary;
    cloned_object = source.clone();
    source.bytes = saved_value.bytes;
    source.length = saved_value.length;
    source.alignment = saved_value.alignment;
    source.endian = saved_value.endian;
    source.image_kind = saved_value.image_kind;
    source.hardware_version = saved_value.hardware_version;
    source.function_generation = saved_value.function_generation;
    source.write_target_kind = saved_value.write_target_kind;
    source.backing_target = saved_value.backing_target;
    source.hmc_target = saved_value.hmc_target;
    source.bar_target = saved_value.bar_target;
    source.field_summary = saved_value.field_summary;
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " image snapshot clone contract failed"}
      );
    end
    if (!same_image_value(source, saved_value) ||
        !same_image_value(snapshot, saved_value)) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " image snapshot changed its source value"}
      );
    end
    return rdma_status::success();
  endfunction

  // 功能：checked_canonical_image_snapshot 先消费 image factory/clone 契约，
  //   再把 submission 使用的 image 直接重建为 exact rdma_hw_image authority。
  // 输入/输出及副作用：source/label/failure_code 为只读输入；
  //   snapshot 先清空，成功时输出与 source/factory snapshot 无别名的
  //   byte/metadata/target 等值 base image，不修改 profile 或 backing。
  // 失败/边界：checked_image_snapshot 失败时原样传播；派生值的 base
  //   投影不满足 journal shape 或重建后不等值时按 failure_code 拒绝，
  //   不影响 completion poll 保留 runtime subtype 的既有契约。
  protected function rdma_status checked_canonical_image_snapshot(
    rdma_hw_image source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_hw_image snapshot
  );
    rdma_hw_image factory_snapshot;
    rdma_hw_image canonical_snapshot;
    rdma_status status;

    snapshot = null;
    status = checked_image_snapshot(
      source, label, failure_code, factory_snapshot
    );
    if (status == null || !status.ok())
      return status;
    canonical_snapshot = new({label, "_canonical"});
    canonical_snapshot.bytes = factory_snapshot.bytes;
    canonical_snapshot.length = factory_snapshot.length;
    canonical_snapshot.alignment = factory_snapshot.alignment;
    canonical_snapshot.endian = factory_snapshot.endian;
    canonical_snapshot.image_kind = factory_snapshot.image_kind;
    canonical_snapshot.hardware_version = factory_snapshot.hardware_version;
    canonical_snapshot.function_generation =
      factory_snapshot.function_generation;
    canonical_snapshot.write_target_kind = factory_snapshot.write_target_kind;
    canonical_snapshot.backing_target = factory_snapshot.backing_target;
    canonical_snapshot.hmc_target = factory_snapshot.hmc_target;
    canonical_snapshot.bar_target = factory_snapshot.bar_target;
    canonical_snapshot.field_summary = factory_snapshot.field_summary;
    if (!rdma_cmq_image_shape_valid(canonical_snapshot) ||
        !same_image_value(canonical_snapshot, factory_snapshot))
      return snapshot_failure(
        failure_code, {label, " canonical image value is invalid"}
      );
    snapshot = canonical_snapshot;
    return rdma_status::success();
  endfunction

  // 功能：checked_completion_payload_snapshot 复制 source、snapshot 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）、snapshot（输出）；checked_completion_payload_snapshot 读取 source、snapshot 并使用字段 snapshot、source_type、status、snapshot_type，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：checked_completion_payload_snapshot 返回 函数体规定的失败状态；具体拒绝条件包括 “CMQ completion payload profile is unavailable”；“CMQ completion payload is null”；“CMQ completion payload snapshot contract failed”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status checked_completion_payload_snapshot(
    uvm_object source,
    output uvm_object snapshot
  );
    uvm_object_wrapper source_type;
    uvm_object_wrapper snapshot_type;
    rdma_status status;

    snapshot = null;
    if (profile == null)
      return invalid_state("CMQ completion payload profile is unavailable");
    if (source == null)
      return invalid_state("CMQ completion payload is null");
    source_type = source.get_object_type();
    if (source_type == null)
      return invalid_state(
        "CMQ completion payload dynamic type is unregistered"
      );
    status = profile.snapshot_completion_payload(source, snapshot);
    if (status == null) begin
      snapshot = null;
      return invalid_state(
        "CMQ completion payload snapshot returned null status"
      );
    end
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    snapshot_type = (snapshot == null) ? null : snapshot.get_object_type();
    if (snapshot == null || snapshot == source || snapshot_type == null ||
        snapshot_type != source_type ||
        !profile.same_completion_payload_value(source, snapshot) ||
        !profile.completion_payload_graph_detached(source, snapshot)) begin
      snapshot = null;
      return invalid_state("CMQ completion payload snapshot contract failed");
    end
    if (!profile.same_completion_payload_value(source, snapshot) ||
        !profile.completion_payload_graph_detached(source, snapshot)) begin
      snapshot = null;
      return invalid_state(
        "CMQ completion payload final snapshot contract failed"
      );
    end
    return rdma_status::success();
  endfunction

  // 功能：先经 factory 候选与 nested clone 契约复制 completion ticket，
  //   再直接构造 exact rdma_cmq_ticket base 值，使 runtime factory override
  //   不泄漏进 retained-journal nonfatal snapshot authority。
  // 输入/输出及副作用：source 为只读 ticket；snapshot 入口清空，成功时
  //   返回与 source/factory candidate 外层及 nested handle/opcode 无别名的
  //   canonical 值；不更新 slot、journal 或 token 账本。
  // 失败/边界：source/nested authority 缺失、factory 构造失败、Function/
  //   CMQ/opcode clone 返回 null/self/变值、source 被改写，或 candidate/canonical
  //   validate/shape 失败时返回 INVALID_STATE 且不发布 partial snapshot。
  protected function rdma_status checked_completion_ticket_snapshot(
    rdma_cmq_ticket source,
    output rdma_cmq_ticket snapshot
  );
    rdma_status status;
    rdma_cmq_ticket factory_snapshot;
    rdma_cmq_ticket canonical_snapshot;
    longint unsigned saved_command_id;
    longint unsigned saved_slot_sequence;
    int unsigned saved_sq_index;
    bit saved_sq_wrap;
    time saved_absolute_deadline;

    snapshot = null;
    if (source == null || source.function_h == null ||
        source.cmq_h == null || source.opcode_key == null)
      return invalid_state("CMQ completion ticket authority is incomplete");
    saved_command_id = source.command_id;
    saved_slot_sequence = source.slot_sequence;
    saved_sq_index = source.sq_index;
    saved_sq_wrap = source.sq_wrap;
    saved_absolute_deadline = source.absolute_deadline;
    factory_snapshot = rdma_cmq_ticket::type_id::create(
      "cmq_polled_completion_ticket"
    );
    if (factory_snapshot == null)
      return invalid_state("CMQ completion ticket construction failed");
    factory_snapshot.command_id = saved_command_id;
    status = checked_function_snapshot(
      source.function_h, "CMQ completion ticket", RDMA_SC_INVALID_STATE,
      factory_snapshot.function_h
    );
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    status = checked_handle_snapshot(
      source.cmq_h, "CMQ completion ticket", RDMA_SC_INVALID_STATE,
      factory_snapshot.cmq_h
    );
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    factory_snapshot.slot_sequence = saved_slot_sequence;
    factory_snapshot.sq_index = saved_sq_index;
    factory_snapshot.sq_wrap = saved_sq_wrap;
    status = checked_opcode_snapshot(
      source.opcode_key, "CMQ completion ticket", RDMA_SC_INVALID_STATE,
      factory_snapshot.opcode_key
    );
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    factory_snapshot.absolute_deadline = saved_absolute_deadline;
    if (source.command_id != saved_command_id ||
        source.slot_sequence != saved_slot_sequence ||
        source.sq_index != saved_sq_index || source.sq_wrap != saved_sq_wrap ||
        source.absolute_deadline != saved_absolute_deadline) begin
      snapshot = null;
      return invalid_state(
        "CMQ completion ticket snapshot changed its source value"
      );
    end
    status = factory_snapshot.validate();
    if (status == null || !status.ok()) begin
      snapshot = null;
      return invalid_state("CMQ completion ticket snapshot validation failed");
    end
    canonical_snapshot = new("cmq_polled_completion_ticket_canonical");
    canonical_snapshot.command_id = factory_snapshot.command_id;
    canonical_snapshot.function_h = factory_snapshot.function_h;
    canonical_snapshot.cmq_h = factory_snapshot.cmq_h;
    canonical_snapshot.slot_sequence = factory_snapshot.slot_sequence;
    canonical_snapshot.sq_index = factory_snapshot.sq_index;
    canonical_snapshot.sq_wrap = factory_snapshot.sq_wrap;
    canonical_snapshot.opcode_key = factory_snapshot.opcode_key;
    canonical_snapshot.absolute_deadline = factory_snapshot.absolute_deadline;
    if (!rdma_cmq_ticket_shape_valid(canonical_snapshot) ||
        !same_ticket_value(canonical_snapshot, source) ||
        canonical_snapshot.function_h == source.function_h ||
        canonical_snapshot.cmq_h == source.cmq_h ||
        canonical_snapshot.opcode_key == source.opcode_key) begin
      snapshot = null;
      return invalid_state(
        "CMQ completion ticket canonical value is invalid"
      );
    end
    snapshot = canonical_snapshot;
    return rdma_status::success();
  endfunction

  // 功能：checked_expected_snapshot 复制 source、label、failure_code、snapshot 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）、label（输入）、failure_code（输入）、snapshot（输出）；checked_expected_snapshot 读取 source、label、failure_code、snapshot 并使用字段 snapshot、status、saved_hardware_opcode、saved_variant、cloned_object，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：checked_expected_snapshot 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_status checked_expected_snapshot(
    rdma_cmq_expected_response source,
    string label,
    rdma_status_code_e failure_code,
    output rdma_cmq_expected_response snapshot
  );
    uvm_object cloned_object;
    rdma_status status;
    bit [31:0] saved_hardware_opcode;
    string saved_variant;

    snapshot = null;
    if (source == null)
      return snapshot_failure(
        failure_code, {label, " expected response is null"}
      );
    status = source.validate();
    if (status == null)
      return snapshot_failure(
        failure_code, {label, " expected validation returned null"}
      );
    if (!status.ok())
      return status;
    saved_hardware_opcode = source.hardware_opcode;
    saved_variant = source.variant;
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " expected snapshot clone contract failed"}
      );
    end
    if (source.hardware_opcode != saved_hardware_opcode ||
        source.variant != saved_variant ||
        snapshot.hardware_opcode != saved_hardware_opcode ||
        snapshot.variant != saved_variant) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " expected snapshot changed its source value"}
      );
    end
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return snapshot_failure(
        failure_code, {label, " expected snapshot validation returned null"}
      );
    end
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  // 功能：snapshot_command_value 逐层验证 command shell/body/signature 的 clone
  //   契约，并把 signature 重建为 journal digest 可接受的 exact image。
  // 输入/输出及副作用：source 为只读 command；snapshot 成功时输出完整
  //   detached 图；staging_invariant_failed 仅标识 body profile 契约故障；不转移
  //   caller body/image 所有权，也不修改 shell 标量。
  // 失败/边界：null source、Function/opcode/body/signature clone 返回
  //   null/self/变值、signature canonical 形状非法或 final validate 失败时不发布
  //   partial snapshot；持久 factory override 不得把派生 image 泄漏到 journal。
  protected function rdma_status snapshot_command_value(
    rdma_cmq_command_desc source,
    output rdma_cmq_command_desc snapshot,
    output bit staging_invariant_failed
  );
    rdma_status status;
    uvm_object cloned_object;
    rdma_cmq_command_desc cloned_command;
    rdma_function_handle function_snapshot;
    rdma_cmq_opcode_key opcode_snapshot;
    rdma_hw_model body_snapshot;
    rdma_hw_image signature_snapshot;
    rdma_function_handle saved_function_source;
    rdma_cmq_opcode_key saved_opcode_source;
    rdma_hw_model saved_body_source;
    rdma_hw_image saved_signature_source;
    string source_type_name;
    bit saved_vfid_override;
    bit [10:0] saved_use_vfid;
    time saved_timeout;
    bit root_source_changed_during_clone;

    snapshot = null;
    staging_invariant_failed = 1'b0;
    if (source == null)
      return invalid_argument("CMQ command is null");
    saved_function_source = source.function_h;
    saved_opcode_source = source.opcode_key;
    saved_body_source = source.body;
    saved_signature_source = source.qpc_signature_source;
    source_type_name = source.get_type_name();
    saved_vfid_override = source.vfid_override;
    saved_use_vfid = source.use_vfid;
    saved_timeout = source.timeout;
    status = checked_function_snapshot(
      source.function_h, "CMQ command", RDMA_SC_INVALID_ARGUMENT,
      function_snapshot
    );
    if (!status.ok())
      return status;
    status = checked_opcode_snapshot(
      source.opcode_key, "CMQ command", RDMA_SC_INVALID_ARGUMENT,
      opcode_snapshot
    );
    if (!status.ok())
      return status;
    status = checked_body_snapshot(
      source.body, "CMQ command", RDMA_SC_INVALID_ARGUMENT, body_snapshot,
      staging_invariant_failed
    );
    if (!status.ok())
      return status;
    signature_snapshot = null;
    if (source.qpc_signature_source != null) begin
      status = checked_canonical_image_snapshot(
        source.qpc_signature_source, "CMQ command signature",
        RDMA_SC_INVALID_ARGUMENT, signature_snapshot
      );
      if (!status.ok())
        return status;
    end

    source.function_h = null;
    source.opcode_key = null;
    source.body = null;
    source.qpc_signature_source = null;
    cloned_object = source.clone();
    root_source_changed_during_clone =
      source.function_h != null || source.opcode_key != null ||
      source.body != null || source.qpc_signature_source != null ||
      source.vfid_override != saved_vfid_override ||
      source.use_vfid != saved_use_vfid || source.timeout != saved_timeout;
    source.function_h = saved_function_source;
    source.opcode_key = saved_opcode_source;
    source.body = saved_body_source;
    source.qpc_signature_source = saved_signature_source;
    source.vfid_override = saved_vfid_override;
    source.use_vfid = saved_use_vfid;
    source.timeout = saved_timeout;
    if (cloned_object == null || !$cast(cloned_command, cloned_object) ||
        cloned_command == source ||
        cloned_command.get_type_name() != source_type_name) begin
      return invalid_argument("CMQ command snapshot clone contract failed");
    end
    if (root_source_changed_during_clone ||
        cloned_command.function_h != null ||
        cloned_command.opcode_key != null ||
        cloned_command.body != null ||
        cloned_command.qpc_signature_source != null ||
        cloned_command.vfid_override != saved_vfid_override ||
        cloned_command.use_vfid != saved_use_vfid ||
        cloned_command.timeout != saved_timeout ||
        !same_handle(source.function_h, function_snapshot) ||
        !same_opcode_value(source.opcode_key, opcode_snapshot) ||
        ((source.qpc_signature_source == null) !=
         (signature_snapshot == null)) ||
        (signature_snapshot != null &&
         (!same_image_value(source.qpc_signature_source,
                            signature_snapshot)))) begin
      return invalid_argument("CMQ command snapshot changed its source value");
    end

    if (!same_body_value(source.body, body_snapshot) ||
        !body_graph_detached(source.body, body_snapshot)) begin
      staging_invariant_failed = 1'b1;
      return invalid_state(
        "CMQ command body snapshot violated its final staging contract"
      );
    end

    snapshot = cloned_command;
    snapshot.function_h = function_snapshot;
    snapshot.opcode_key = opcode_snapshot;
    snapshot.body = body_snapshot;
    snapshot.qpc_signature_source = signature_snapshot;
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return invalid_state("CMQ command validation returned null status");
    end
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  // 功能：make_mapping_snapshot 复制 source、name、snapshot 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）、name（输入）、snapshot（输出）；make_mapping_snapshot 读取 source、name、snapshot 并使用字段 snapshot、saved_value、status、saved_value.requester_bdf、saved_value.pasid_valid、saved_value.pasid、saved_value.dma_domain_valid、saved_value.dma_domain_id，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：make_mapping_snapshot 返回 RDMA_SC_INVALID_STATE；具体拒绝条件包括 “CMQ dependency mapping source is null”；“CMQ dependency mapping value capture failed”；“CMQ dependency mapping clone contract failed”；“CMQ dependency mapping snapshot changed value”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status make_mapping_snapshot(
    rdma_dma_mapping source,
    string name,
    output rdma_dma_mapping snapshot
  );
    rdma_status status;
    uvm_object cloned_object;
    rdma_dma_mapping saved_value;

    snapshot = null;
    if (source == null)
      return invalid_state("CMQ dependency mapping source is null");
    saved_value = rdma_dma_mapping::type_id::create({name, "_saved"});
    if (saved_value == null)
      return invalid_state("CMQ dependency mapping value capture failed");
    status = checked_function_snapshot(
      source.function_h, "CMQ dependency mapping", RDMA_SC_INVALID_STATE,
      saved_value.function_h
    );
    if (!status.ok()) begin
      return status;
    end
    status = checked_handle_snapshot(
      source.owner_h, "CMQ dependency mapping owner", RDMA_SC_INVALID_STATE,
      saved_value.owner_h
    );
    if (!status.ok()) begin
      return status;
    end
    saved_value.requester_bdf = source.requester_bdf;
    saved_value.pasid_valid = source.pasid_valid;
    saved_value.pasid = source.pasid;
    saved_value.dma_domain_valid = source.dma_domain_valid;
    saved_value.dma_domain_id = source.dma_domain_id;
    saved_value.backing_addr = source.backing_addr;
    saved_value.iova = source.iova;
    saved_value.size = source.size;
    saved_value.direction = source.direction;
    saved_value.permissions = source.permissions;
    saved_value.state = source.state;
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return invalid_state("CMQ dependency mapping clone contract failed");
    end
    if (!same_mapping_value(source, saved_value) ||
        !same_mapping_value(snapshot, saved_value) ||
        snapshot.function_h == source.function_h ||
        snapshot.owner_h == source.owner_h) begin
      snapshot = null;
      return invalid_state("CMQ dependency mapping snapshot changed value");
    end
    return rdma_status::success();
  endfunction

  // 功能：make_ticket_value 先经 UVM factory 构造并 clone 候选 ticket，使测试可观测
  //   factory/clone 故障；候选通过后再直接构造 exact rdma_cmq_ticket，
  //   作为 journal digest 可接受的 canonical authority 值。
  // 输入/输出及副作用：command_id、Function/CMQ handle、slot_sequence、SQ
  //   位置、opcode_key 与 absolute_deadline 为输入；ticket 先清空，成功时输出
  //   与输入及 factory 候选图均无别名的 exact base 值，不改写输入。
  // 失败/边界：factory 构造、nested 快照、validate/clone 契约、direct
  //   canonical 快照或最终形状任一失败均返回 INVALID_STATE；已武装
  //   clone-self 故障仍在 canonicalization 前被消费，且失败不发布部分 ticket。
  protected function rdma_status make_ticket_value(
    string name,
    longint unsigned command_id,
    rdma_function_handle function_h,
    rdma_handle cmq_h,
    longint unsigned slot_sequence,
    int unsigned sq_index,
    bit sq_wrap,
    rdma_cmq_opcode_key opcode_key,
    time absolute_deadline,
    output rdma_cmq_ticket ticket
  );
    rdma_status status;
    uvm_object cloned_object;
    rdma_cmq_ticket detached_ticket;
    rdma_cmq_ticket canonical_ticket;
    rdma_handle function_snapshot_base;
    rdma_handle cmq_snapshot;
    rdma_function_handle function_snapshot;
    rdma_cmq_opcode_key opcode_snapshot;

    ticket = rdma_cmq_ticket::type_id::create(name);
    if (ticket == null)
      return invalid_state("CMQ ticket construction failed");
    ticket.command_id = command_id;
    status = checked_function_snapshot(
      function_h, "CMQ ticket", RDMA_SC_INVALID_STATE, ticket.function_h
    );
    if (!status.ok()) begin
      ticket = null;
      return status;
    end
    status = checked_handle_snapshot(
      cmq_h, "CMQ ticket", RDMA_SC_INVALID_STATE, ticket.cmq_h
    );
    if (!status.ok()) begin
      ticket = null;
      return status;
    end
    ticket.slot_sequence = slot_sequence;
    ticket.sq_index = sq_index;
    ticket.sq_wrap = sq_wrap;
    status = checked_opcode_snapshot(
      opcode_key, "CMQ ticket", RDMA_SC_INVALID_STATE, ticket.opcode_key
    );
    if (!status.ok()) begin
      ticket = null;
      return status;
    end
    ticket.absolute_deadline = absolute_deadline;
    status = ticket.validate();
    if (status == null || !status.ok()) begin
      ticket = null;
      return invalid_state("CMQ ticket validation failed");
    end
    cloned_object = ticket.clone();
    if (cloned_object == null ||
        !$cast(detached_ticket, cloned_object) ||
        detached_ticket == ticket ||
        !same_ticket_value(detached_ticket, ticket) ||
        detached_ticket.function_h == ticket.function_h ||
        detached_ticket.cmq_h == ticket.cmq_h ||
        detached_ticket.opcode_key == ticket.opcode_key) begin
      ticket = null;
      return invalid_state("CMQ ticket snapshot clone contract failed");
    end
    if (!rdma_cmq_try_snapshot_handle_direct(
          detached_ticket.function_h, 1'b0, function_snapshot_base
        ) || !$cast(function_snapshot, function_snapshot_base) ||
        !rdma_cmq_try_snapshot_handle_direct(
          detached_ticket.cmq_h, 1'b0, cmq_snapshot
        ) || !rdma_cmq_try_snapshot_opcode_key_direct(
          detached_ticket.opcode_key, opcode_snapshot
        )) begin
      ticket = null;
      return invalid_state("CMQ ticket canonical snapshot failed");
    end
    canonical_ticket = new({name, "_canonical"});
    canonical_ticket.command_id = detached_ticket.command_id;
    canonical_ticket.function_h = function_snapshot;
    canonical_ticket.cmq_h = cmq_snapshot;
    canonical_ticket.slot_sequence = detached_ticket.slot_sequence;
    canonical_ticket.sq_index = detached_ticket.sq_index;
    canonical_ticket.sq_wrap = detached_ticket.sq_wrap;
    canonical_ticket.opcode_key = opcode_snapshot;
    canonical_ticket.absolute_deadline = detached_ticket.absolute_deadline;
    if (!rdma_cmq_ticket_shape_valid(canonical_ticket) ||
        !same_ticket_value(canonical_ticket, detached_ticket)) begin
      ticket = null;
      return invalid_state("CMQ ticket canonical value is invalid");
    end
    ticket = canonical_ticket;
    return rdma_status::success();
  endfunction

  // 功能：checked_slot_context_snapshot 复制 source、snapshot 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）、snapshot（输出）；checked_slot_context_snapshot 读取 source、snapshot 并使用字段 snapshot、cloned_object，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：checked_slot_context_snapshot 返回 函数体规定的失败状态；具体拒绝条件包括 “CMQ slot context source is null”；“CMQ slot context snapshot clone contract failed”；“CMQ slot context snapshot changed value”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status checked_slot_context_snapshot(
    rdma_cmq_slot_context source,
    output rdma_cmq_slot_context snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return invalid_state("CMQ slot context source is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return invalid_state("CMQ slot context snapshot clone contract failed");
    end
    if (snapshot.function_h == null || source.function_h == null ||
        !snapshot.function_h.same_instance(source.function_h) ||
        snapshot.cmq_h == null || source.cmq_h == null ||
        !snapshot.cmq_h.same_instance(source.cmq_h) ||
        snapshot.backing_addr.value != source.backing_addr.value ||
        snapshot.relative_offset != source.relative_offset ||
        snapshot.slot_sequence != source.slot_sequence ||
        snapshot.sq_index != source.sq_index ||
        snapshot.sq_wrap != source.sq_wrap ||
        snapshot.function_h == source.function_h ||
        snapshot.cmq_h == source.cmq_h) begin
      snapshot = null;
      return invalid_state("CMQ slot context snapshot changed value");
    end
    return rdma_status::success();
  endfunction

  // 功能：checked_record_snapshot 先验证 factory-backed slot record clone 契约，
  //   再直接重建 exact rdma_cmq_slot_record/ticket/expected 值供预分配发布。
  // 输入/输出及副作用：source 为只读候选；snapshot 先清空，成功时输出
  //   与 source/factory clone 都无别名的 exact graph，不修改 slot/ticket 输入。
  // 失败/边界：source/ticket/expected 不完整，clone 返回 null/self/变值，
  //   nested direct snapshot 失败，或 canonical record 不等值时返回 INVALID_STATE；
  //   factory clone-self 故障仍在 exact 重建前可观测，失败不发布部分图。
  protected function rdma_status checked_record_snapshot(
    rdma_cmq_slot_record source,
    output rdma_cmq_slot_record snapshot
  );
    uvm_object cloned_object;
    rdma_cmq_slot_record factory_snapshot;
    rdma_cmq_slot_record canonical_snapshot;
    rdma_cmq_ticket canonical_ticket;
    rdma_cmq_expected_response canonical_expected;
    rdma_handle function_snapshot_base;
    rdma_handle cmq_snapshot;
    rdma_function_handle function_snapshot;
    rdma_cmq_opcode_key opcode_snapshot;
    rdma_status status;

    snapshot = null;
    if (source == null)
      return invalid_state("CMQ slot record source is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(factory_snapshot, cloned_object) ||
        factory_snapshot == source) begin
      snapshot = null;
      return invalid_state("CMQ slot record snapshot clone contract failed");
    end
    if (factory_snapshot.slot_sequence != source.slot_sequence ||
        factory_snapshot.sq_index != source.sq_index ||
        factory_snapshot.sq_wrap != source.sq_wrap ||
        factory_snapshot.state != source.state ||
        factory_snapshot.command_token != source.command_token ||
        factory_snapshot.batch_key != source.batch_key ||
        factory_snapshot.journal_item_index != source.journal_item_index ||
        !same_ticket_value(factory_snapshot.ticket, source.ticket) ||
        !same_expected_value(factory_snapshot.expected, source.expected) ||
        factory_snapshot.ticket == source.ticket ||
        factory_snapshot.expected == source.expected) begin
      snapshot = null;
      return invalid_state("CMQ slot record snapshot changed value");
    end
    if (!rdma_cmq_try_snapshot_handle_direct(
          factory_snapshot.ticket.function_h, 1'b0, function_snapshot_base
        ) || !$cast(function_snapshot, function_snapshot_base) ||
        !rdma_cmq_try_snapshot_handle_direct(
          factory_snapshot.ticket.cmq_h, 1'b0, cmq_snapshot
        ) || !rdma_cmq_try_snapshot_opcode_key_direct(
          factory_snapshot.ticket.opcode_key, opcode_snapshot
        )) begin
      return invalid_state("CMQ slot record ticket canonical snapshot failed");
    end
    canonical_ticket = new("cmq_slot_record_canonical_ticket");
    canonical_ticket.command_id = factory_snapshot.ticket.command_id;
    canonical_ticket.function_h = function_snapshot;
    canonical_ticket.cmq_h = cmq_snapshot;
    canonical_ticket.slot_sequence = factory_snapshot.ticket.slot_sequence;
    canonical_ticket.sq_index = factory_snapshot.ticket.sq_index;
    canonical_ticket.sq_wrap = factory_snapshot.ticket.sq_wrap;
    canonical_ticket.opcode_key = opcode_snapshot;
    canonical_ticket.absolute_deadline =
      factory_snapshot.ticket.absolute_deadline;
    canonical_expected = new("cmq_slot_record_canonical_expected");
    canonical_expected.hardware_opcode =
      factory_snapshot.expected.hardware_opcode;
    canonical_expected.variant = factory_snapshot.expected.variant;
    status = canonical_expected.validate();
    if (!rdma_cmq_ticket_shape_valid(canonical_ticket) || status == null ||
        !status.ok() ||
        !same_ticket_value(canonical_ticket, factory_snapshot.ticket) ||
        !same_expected_value(canonical_expected, factory_snapshot.expected))
      return invalid_state("CMQ slot record canonical value is invalid");
    canonical_snapshot = new("cmq_slot_record_canonical_snapshot");
    canonical_snapshot.slot_sequence = factory_snapshot.slot_sequence;
    canonical_snapshot.sq_index = factory_snapshot.sq_index;
    canonical_snapshot.sq_wrap = factory_snapshot.sq_wrap;
    canonical_snapshot.state = factory_snapshot.state;
    canonical_snapshot.ticket = canonical_ticket;
    canonical_snapshot.expected = canonical_expected;
    canonical_snapshot.command_token = factory_snapshot.command_token;
    canonical_snapshot.batch_key = factory_snapshot.batch_key;
    canonical_snapshot.journal_item_index =
      factory_snapshot.journal_item_index;
    snapshot = canonical_snapshot;
    return rdma_status::success();
  endfunction

  // 功能：checked_dependency_snapshot 复制 source、snapshot 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）、snapshot（输出）；checked_dependency_snapshot 读取 source、snapshot 并使用字段 snapshot、cloned_object，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：checked_dependency_snapshot 返回 函数体规定的失败状态；具体拒绝条件包括 “CMQ dependency source is null”；“CMQ dependency snapshot clone contract failed”；“CMQ dependency snapshot changed value”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status checked_dependency_snapshot(
    rdma_doorbell_dependency source,
    output rdma_doorbell_dependency snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return invalid_state("CMQ dependency source is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return invalid_state("CMQ dependency snapshot clone contract failed");
    end
    if (!same_dependency_value(snapshot, source) ||
        snapshot.mapping == source.mapping || snapshot.image == source.image) begin
      snapshot = null;
      return invalid_state("CMQ dependency snapshot changed value");
    end
    return rdma_status::success();
  endfunction

  // 功能：checked_doorbell_desc_snapshot 复制 source、snapshot 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）、snapshot（输出）；checked_doorbell_desc_snapshot 读取 source、snapshot 并使用字段 snapshot、cloned_object，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：checked_doorbell_desc_snapshot 返回 函数体规定的失败状态；具体拒绝条件包括 “CMQ doorbell descriptor source is null”；“CMQ doorbell descriptor snapshot changed value”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status checked_doorbell_desc_snapshot(
    rdma_doorbell_desc source,
    output rdma_doorbell_desc snapshot
  );
    uvm_object cloned_object;

    snapshot = null;
    if (source == null)
      return invalid_state("CMQ doorbell descriptor source is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source) begin
      snapshot = null;
      return invalid_state(
        "CMQ doorbell descriptor snapshot clone contract failed"
      );
    end
    if (snapshot.kind != source.kind ||
        snapshot.function_h == null || source.function_h == null ||
        !snapshot.function_h.same_instance(source.function_h) ||
        snapshot.target_h == null || source.target_h == null ||
        !snapshot.target_h.same_instance(source.target_h) ||
        snapshot.notify_bar_id != source.notify_bar_id ||
        snapshot.relative_offset != source.relative_offset ||
        snapshot.width != source.width || snapshot.endian != source.endian ||
        !same_image_value(snapshot.payload_image, source.payload_image) ||
        snapshot.barrier_policy != source.barrier_policy ||
        snapshot.write_combining_policy != source.write_combining_policy ||
        snapshot.allow_merge != source.allow_merge ||
        snapshot.merge_requested != source.merge_requested ||
        snapshot.timeout != source.timeout ||
        snapshot.readback_policy != source.readback_policy ||
        snapshot.dependencies.size() != source.dependencies.size() ||
        snapshot.function_h == source.function_h ||
        snapshot.target_h == source.target_h ||
        snapshot.payload_image == source.payload_image) begin
      snapshot = null;
      return invalid_state("CMQ doorbell descriptor snapshot changed value");
    end
    foreach (source.dependencies[i]) begin
      if (!same_dependency_value(snapshot.dependencies[i],
                                 source.dependencies[i]) ||
          snapshot.dependencies[i] == source.dependencies[i]) begin
        snapshot = null;
        return invalid_state(
          "CMQ doorbell descriptor dependency snapshot changed value"
        );
      end
    end
    return rdma_status::success();
  endfunction

  // 功能：sqe_metadata_status 校验 image、expected_backing_target 与当前对象状态的一致性，并显式处理“CMQ profile returned a null SQE”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：image（输入）、expected_backing_target（输入）；sqe_metadata_status 读取 image、expected_backing_target 并使用字段 rdma_status、prepared_binding.generation、value；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：sqe_metadata_status 返回 RDMA_SC_STALE_GENERATION、RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“CMQ profile returned a null SQE”“CMQ SQE is not exactly 64 bytes”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status sqe_metadata_status(
    rdma_hw_image image,
    longint unsigned expected_backing_target
  );
    if (image == null)
      return invalid_state("CMQ profile returned a null SQE");
    if (image.length != CMQE_BYTES || image.bytes.size() != CMQE_BYTES)
      return invalid_argument("CMQ SQE is not exactly 64 bytes");
    if (image.alignment != CMQE_BYTES)
      return invalid_argument("CMQ SQE alignment is not 64 bytes");
    if (!(image.endian inside {RDMA_ENDIAN_LITTLE, RDMA_ENDIAN_BIG}) ||
        image.hardware_version == 0)
      return invalid_argument("CMQ SQE metadata is incomplete");
    if (image.image_kind != RDMA_IMAGE_CMQ_SQE)
      return invalid_argument("CMQ profile image is not an SQE");
    if (image.function_generation != prepared_binding.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION, "CMQ SQE Function generation is stale"
      );
    if (image.write_target_kind != RDMA_HW_TARGET_BACKING)
      return invalid_argument("CMQ SQE write target is not backing memory");
    if (image.hmc_target.value != 0 || image.bar_target.value != 0)
      return invalid_argument("CMQ SQE has an inactive write target");
    if (image.backing_target.value != expected_backing_target)
      return invalid_argument(
        "CMQ SQE backing target does not match compacted slot"
      );
    return rdma_status::success();
  endfunction

  // 功能：doorbell_metadata_status 校验 image 与当前对象状态的一致性，并显式处理“CMQ profile returned a null doorbell image”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：image（输入）；doorbell_metadata_status 读取 image 并使用字段 rdma_status、prepared_binding.generation、value、prepared_binding.notify_size；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：doorbell_metadata_status 返回 RDMA_SC_STALE_GENERATION、RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“CMQ profile returned a null doorbell image”“CMQ doorbell image length is invalid”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status doorbell_metadata_status(
    rdma_hw_image image
  );
    if (image == null)
      return invalid_state("CMQ profile returned a null doorbell image");
    if (image.length == 0 || image.bytes.size() != image.length)
      return invalid_argument("CMQ doorbell image length is invalid");
    if (image.alignment == 0 ||
        (image.alignment & (image.alignment - 1'b1)) != 0)
      return invalid_argument("CMQ doorbell image alignment is invalid");
    if (!(image.endian inside {RDMA_ENDIAN_LITTLE, RDMA_ENDIAN_BIG}) ||
        image.hardware_version == 0)
      return invalid_argument("CMQ doorbell metadata is incomplete");
    if (image.image_kind != RDMA_IMAGE_DOORBELL)
      return invalid_argument("CMQ profile image is not a doorbell");
    if (image.function_generation != prepared_binding.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ doorbell Function generation is stale"
      );
    if (image.write_target_kind != RDMA_HW_TARGET_BAR)
      return invalid_argument("CMQ doorbell target is not a BAR");
    if (image.backing_target.value != 0 || image.hmc_target.value != 0)
      return invalid_argument("CMQ doorbell has an inactive write target");
    if ((image.bar_target.value & (image.alignment - 1'b1)) != 0)
      return invalid_argument("CMQ doorbell BAR target is misaligned");
    if (image.bar_target.value > prepared_binding.notify_size ||
        image.length >
          (prepared_binding.notify_size - image.bar_target.value))
      return invalid_argument(
        "CMQ doorbell target is outside the notify aperture"
      );
    return rdma_status::success();
  endfunction

  // 功能：build_runtime_desc 创建独立的 rdma_status；根据 request_context、cmq、mapping、runtime 设置字段 runtime、status、runtime.function_h、runtime.cmq_h、runtime.sq_iova、cq_iova.value、runtime.sq_depth、runtime.cq_depth、runtime.entry_bytes、runtime.initial_sq_valid，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：request_context（输入）、cmq（输入）、mapping（输入）、runtime（输出）；build_runtime_desc 读取 request_context、cmq、mapping、runtime 并使用字段 runtime、status、runtime.function_h、runtime.cmq_h、runtime.sq_iova、cq_iova.value、runtime.sq_depth、runtime.cq_depth，并写入 runtime；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：build_runtime_desc 返回 RDMA_SC_DMA_TRANSLATION、RDMA_SC_INVALID_STATE；典型拒绝条件为“CMQ SQ-to-CQ IOVA addition overflows”“CMQ runtime descriptor construction failed”；失败路径不提交部分状态或转移未声明资源。
  protected virtual function rdma_status build_runtime_desc(
    rdma_dma_request_context request_context,
    rdma_cmq cmq,
    rdma_dma_mapping mapping,
    output rdma_cmq_runtime_desc runtime
  );
    rdma_status status;
    rdma_function_handle runtime_function;
    rdma_handle runtime_cmq;

    runtime = null;
    if (mapping.iova.value >
        (64'hffff_ffff_ffff_ffff - CQ_OFFSET))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ SQ-to-CQ IOVA addition overflows"
      );
    runtime = rdma_cmq_runtime_desc::type_id::create(
      "cmq_runtime_candidate"
    );
    if (runtime == null)
      return invalid_state("CMQ runtime descriptor construction failed");
    status = clone_function_handle_fields(request_context.function_h,
                                          "cmq_runtime_function",
                                          runtime_function);
    if (!status.ok()) begin
      runtime = null;
      return status;
    end
    status = clone_handle_fields(cmq.handle, "cmq_runtime_cmq",
                                 runtime_cmq);
    if (!status.ok()) begin
      runtime = null;
      return status;
    end
    runtime.function_h = runtime_function;
    runtime.cmq_h = runtime_cmq;
    runtime.sq_iova = mapping.iova;
    runtime.cq_iova.value = mapping.iova.value + CQ_OFFSET;
    runtime.sq_depth = CMQ_DEPTH;
    runtime.cq_depth = CMQ_DEPTH;
    runtime.entry_bytes = CMQE_BYTES;
    runtime.initial_sq_valid = 1'b1;
    runtime.initial_cq_owner = 1'b1;
    runtime.initial_doorbell_polarity = 1'b0;
    status = runtime.validate();
    if (status == null) begin
      runtime = null;
      return invalid_state("CMQ runtime descriptor returned null status");
    end
    if (!status.ok())
      runtime = null;
    return status;
  endfunction

  // 功能：在 rdma_cmq_engine 中，publish_runtime_snapshot 提交当前事务阶段并发布 detached 结果，只有成功路径才推进游标或状态。
  // 输入/输出及副作用：source（输入）、snapshot（输出）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过
  //   output 返回结果。
  // 失败/边界：队列未激活、credit 不足、请求身份过期或后端写入失败时返回错误；不得提前推进游标或重复提交。
  protected virtual function rdma_status publish_runtime_snapshot(
    rdma_cmq_runtime_desc source,
    output rdma_cmq_runtime_desc snapshot
  );
    rdma_status status;
    rdma_function_handle runtime_function;
    rdma_handle runtime_cmq;

    snapshot = null;
    if (source == null)
      return invalid_state("CMQ runtime snapshot source is null");
    snapshot = rdma_cmq_runtime_desc::type_id::create(
      "cmq_runtime_snapshot"
    );
    if (snapshot == null)
      return invalid_state("CMQ runtime snapshot construction failed");
    status = clone_function_handle_fields(source.function_h,
                                          "cmq_published_function",
                                          runtime_function);
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    status = clone_handle_fields(source.cmq_h, "cmq_published_cmq",
                                 runtime_cmq);
    if (!status.ok()) begin
      snapshot = null;
      return status;
    end
    snapshot.function_h = runtime_function;
    snapshot.cmq_h = runtime_cmq;
    snapshot.sq_iova = source.sq_iova;
    snapshot.cq_iova = source.cq_iova;
    snapshot.sq_depth = source.sq_depth;
    snapshot.cq_depth = source.cq_depth;
    snapshot.entry_bytes = source.entry_bytes;
    snapshot.initial_sq_valid = source.initial_sq_valid;
    snapshot.initial_cq_owner = source.initial_cq_owner;
    snapshot.initial_doorbell_polarity =
      source.initial_doorbell_polarity;
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return invalid_state("CMQ runtime snapshot returned null status");
    end
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  // 设计说明：journal 的公开/hostile-factory 路径必须始终返回直接构造的
  //   status；集中 helper 只统一类别字段，不改变下游错误码或重试语义。
  // 功能：直接构造指定 code/message 的 journal status，绕开 raw UVM factory。
  // 输入/输出及副作用：code/message 为只读输入；返回调用方拥有的新 status。
  // 失败/边界：未知 code 由 rdma_cmq_direct_status 保守归类；始终返回非空值。
  protected function rdma_status journal_status(
    rdma_status_code_e code,
    string message = ""
  );
    return rdma_cmq_direct_status(code, message);
  endfunction

  // 功能：逐字段比较两个 frozen recovery-owner 值，不把句柄 identity 当对象别名。
  // 输入/输出及副作用：lhs/rhs 为只读输入；返回完整公开值是否相等。
  // 失败/边界：任一 owner 形状非法、嵌套句柄/identity 缺失或值漂移返回 0。
  protected function bit same_journal_owner_value(
    rdma_cmq_recovery_owner lhs,
    rdma_cmq_recovery_owner rhs
  );
    if (!rdma_cmq_frozen_owner_shape_valid(lhs) ||
        !rdma_cmq_frozen_owner_shape_valid(rhs))
      return 1'b0;
    if (lhs.is_legacy_unmigrated() || rhs.is_legacy_unmigrated())
      return lhs.is_legacy_unmigrated() && rhs.is_legacy_unmigrated();
    return lhs.workflow == rhs.workflow &&
           lhs.resource_h != null && rhs.resource_h != null &&
           lhs.resource_h.same_instance(rhs.resource_h) &&
           lhs.transaction_id == rhs.transaction_id &&
           lhs.allowed_actions == rhs.allowed_actions &&
           lhs.function_identity != null && rhs.function_identity != null &&
           lhs.function_identity.same_incarnation(rhs.function_identity) &&
           lhs.admission_attempt_id == rhs.admission_attempt_id &&
           lhs.frozen == rhs.frozen;
  endfunction

  // 功能：比较 DMA request context 的全部公开 authority 投影和可选 owner 值。
  // 输入/输出及副作用：lhs/rhs 为只读输入；只返回字段相等结果，不执行 DMA。
  // 失败/边界：null、Function 缺失、可选 owner 形状不一致或任一 route/role 字段
  //   漂移时返回 0；不调用外部 adapter。
  protected function bit same_journal_dma_context_value(
    rdma_dma_request_context lhs,
    rdma_dma_request_context rhs
  );
    if (lhs == null || rhs == null || lhs.function_h == null ||
        rhs.function_h == null ||
        !lhs.function_h.same_instance(rhs.function_h))
      return 1'b0;
    if ((lhs.owner_h == null) != (rhs.owner_h == null))
      return 1'b0;
    if (lhs.owner_h != null && !lhs.owner_h.same_instance(rhs.owner_h))
      return 1'b0;
    return lhs.requester_bdf == rhs.requester_bdf &&
           lhs.pasid_valid == rhs.pasid_valid && lhs.pasid == rhs.pasid &&
           lhs.dma_domain_valid == rhs.dma_domain_valid &&
           lhs.dma_domain_id == rhs.dma_domain_id &&
           lhs.route == rhs.route && lhs.reset_epoch == rhs.reset_epoch &&
           lhs.route_valid == rhs.route_valid &&
           lhs.epoch_valid == rhs.epoch_valid &&
           lhs.queue_role_valid == rhs.queue_role_valid &&
           lhs.queue_role == rhs.queue_role;
  endfunction

  // 功能：比较 DMA mapping 的每个公开字段，同时保留外部 UMEM/PBL/MW 非拥有引用。
  // 输入/输出及副作用：lhs/rhs 为只读输入；返回公开投影是否完全相等。
  // 失败/边界：null、Function/owner 形状不一致、route/range/permission/state 或
  //   外部引用漂移返回 0；本函数不宣称私有 allocation authority 相等。
  protected function bit same_journal_mapping_public_value(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null || lhs.function_h == null ||
        rhs.function_h == null ||
        !lhs.function_h.same_instance(rhs.function_h))
      return 1'b0;
    if ((lhs.owner_h == null) != (rhs.owner_h == null))
      return 1'b0;
    if (lhs.owner_h != null && !lhs.owner_h.same_instance(rhs.owner_h))
      return 1'b0;
    return lhs.requester_bdf == rhs.requester_bdf &&
           lhs.pasid_valid == rhs.pasid_valid && lhs.pasid == rhs.pasid &&
           lhs.dma_domain_valid == rhs.dma_domain_valid &&
           lhs.dma_domain_id == rhs.dma_domain_id &&
           lhs.route == rhs.route && lhs.reset_epoch == rhs.reset_epoch &&
           lhs.route_valid == rhs.route_valid &&
           lhs.epoch_valid == rhs.epoch_valid &&
           lhs.backing_addr.value == rhs.backing_addr.value &&
           lhs.iova.value == rhs.iova.value && lhs.size == rhs.size &&
           lhs.direction == rhs.direction &&
           lhs.permissions == rhs.permissions && lhs.state == rhs.state &&
           lhs.umem_ref == rhs.umem_ref && lhs.pbl_ref == rhs.pbl_ref &&
           lhs.mw_ref == rhs.mw_ref && lhs.umem_backed == rhs.umem_backed &&
           lhs.umem_page_count == rhs.umem_page_count;
  endfunction

  // 功能：比较 execution result 中不可变 command identity 的全部标量/文本。
  // 输入/输出及副作用：lhs/rhs 为只读输入；返回值相等结果，无账本副作用。
  // 失败/边界：null、非法 Function kind、零 UID/generation 或文本字段漂移返回 0。
  protected function bit same_journal_command_identity_value(
    rdma_cmq_command_identity lhs,
    rdma_cmq_command_identity rhs
  );
    if (lhs == null || rhs == null ||
        lhs.function_kind != RDMA_RESOURCE_FUNCTION ||
        rhs.function_kind != RDMA_RESOURCE_FUNCTION ||
        lhs.function_uid == 0 || rhs.function_uid == 0 ||
        lhs.generation == 0 || rhs.generation == 0 ||
        lhs.profile_name.len() == 0 || rhs.profile_name.len() == 0 ||
        lhs.variant.len() == 0 || rhs.variant.len() == 0)
      return 1'b0;
    return lhs.function_kind == rhs.function_kind &&
           lhs.function_uid == rhs.function_uid &&
           lhs.global_function_id == rhs.global_function_id &&
           lhs.generation == rhs.generation &&
           lhs.profile_name == rhs.profile_name &&
           lhs.opcode == rhs.opcode && lhs.variant == rhs.variant;
  endfunction

  // 功能：直接复制 DMA request context 及两个嵌套 handle，供 journal 图拥有 detached 值。
  // 输入/输出及副作用：source 为只读输入，snapshot 入口清空；成功发布新 context。
  // 失败/边界：null/未知 outer subtype、source validate 失败、handle subtype 不受支持，
  //   或候选值/分离校验失败时返回 INVALID_ARGUMENT/null，不调用 clone/copy/factory。
  protected function rdma_status snapshot_journal_dma_context_locked(
    input rdma_dma_request_context source,
    output rdma_dma_request_context snapshot
  );
    rdma_dma_request_context candidate;
    rdma_handle function_snapshot_base;
    rdma_handle owner_snapshot;
    rdma_status status;

    snapshot = null;
    if (source == null ||
        source.get_object_type() != rdma_dma_request_context::get_type())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal DMA context is null or unsupported"
      );
    status = source.validate();
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal DMA context validation returned null"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    if (!rdma_cmq_try_snapshot_handle_direct(
          source.function_h, 1'b0, function_snapshot_base
        ) || !rdma_cmq_try_snapshot_handle_direct(
          source.owner_h, 1'b1, owner_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal DMA context nested snapshot failed"
      );

    candidate = new("journal_dma_context_snapshot");
    if (!$cast(candidate.function_h, function_snapshot_base))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal DMA Function snapshot subtype is invalid"
      );
    candidate.requester_bdf = source.requester_bdf;
    candidate.pasid_valid = source.pasid_valid;
    candidate.pasid = source.pasid;
    candidate.dma_domain_valid = source.dma_domain_valid;
    candidate.dma_domain_id = source.dma_domain_id;
    candidate.route = source.route;
    candidate.reset_epoch = source.reset_epoch;
    candidate.route_valid = source.route_valid;
    candidate.epoch_valid = source.epoch_valid;
    candidate.owner_h = owner_snapshot;
    candidate.queue_role_valid = source.queue_role_valid;
    candidate.queue_role = source.queue_role;
    if (!same_journal_dma_context_value(source, candidate) ||
        candidate.function_h == source.function_h ||
        (source.owner_h != null && candidate.owner_h == source.owner_h))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal DMA context snapshot is unequal or aliased"
      );
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 设计说明：mapping 的 concrete adapter 私有 allocation identity 不能由 engine
  //   猜测；先取得 opaque release-authority subtype，再显式覆盖全部公开投影。
  // 功能：通过 adapter seam 复制 mapping 私有 authority，并直接复制所有公开字段/handle。
  // 输入/输出及副作用：source 为非拥有输入，snapshot 入口清空；adapter seam 仅做
  //   authority snapshot/equivalence 查询，成功结果由 journal 图拥有。
  // 失败/边界：seam null/error、自别名/错误 subtype、嵌套 handle 或完整公开值验证
  //   失败时返回非空错误与 null；绝不降级成 base mapping 或 digest 替代品。
  protected function rdma_status snapshot_journal_mapping_locked(
    input rdma_dma_mapping source,
    output rdma_dma_mapping snapshot
  );
    rdma_dma_mapping candidate;
    rdma_handle function_snapshot_base;
    rdma_handle owner_snapshot;
    rdma_status status;

    snapshot = null;
    if (source == null)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT, "CMQ journal mapping is null"
      );
    status = source.snapshot_release_authority(candidate);
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal mapping authority snapshot returned null status"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    if (candidate == null || candidate == source ||
        candidate.get_object_type() != source.get_object_type())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal mapping authority snapshot is null, aliased or sliced"
      );
    if (!rdma_cmq_try_snapshot_handle_direct(
          source.function_h, 1'b0, function_snapshot_base
        ) || !rdma_cmq_try_snapshot_handle_direct(
          source.owner_h, 1'b1, owner_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal mapping nested handle snapshot failed"
      );
    if (!$cast(candidate.function_h, function_snapshot_base))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal mapping Function snapshot subtype is invalid"
      );
    candidate.requester_bdf = source.requester_bdf;
    candidate.pasid_valid = source.pasid_valid;
    candidate.pasid = source.pasid;
    candidate.dma_domain_valid = source.dma_domain_valid;
    candidate.dma_domain_id = source.dma_domain_id;
    candidate.route = source.route;
    candidate.reset_epoch = source.reset_epoch;
    candidate.route_valid = source.route_valid;
    candidate.epoch_valid = source.epoch_valid;
    candidate.backing_addr = source.backing_addr;
    candidate.iova = source.iova;
    candidate.size = source.size;
    candidate.direction = source.direction;
    candidate.permissions = source.permissions;
    candidate.state = source.state;
    candidate.owner_h = owner_snapshot;
    candidate.umem_ref = source.umem_ref;
    candidate.pbl_ref = source.pbl_ref;
    candidate.mw_ref = source.mw_ref;
    candidate.umem_backed = source.umem_backed;
    candidate.umem_page_count = source.umem_page_count;

    status = source.release_authority_status(candidate);
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal mapping authority verification returned null status"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    if (!same_journal_mapping_public_value(source, candidate) ||
        candidate.function_h == source.function_h ||
        (source.owner_h != null && candidate.owner_h == source.owner_h))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal mapping snapshot changed public value or retained an alias"
      );
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：使用指定 exact profile service 复制 command body，再直接构造 command shell。
  // 输入/输出及副作用：source、已 canonicalize 的 detached_owner、context/profile
  //   为输入，snapshot 入口清空；成功发布完整 detached command。
  // 失败/边界：未知 body、profile seam null/error、outer/nested subtype 非法、owner
  //   不等值/仍别名或 shell 字段漂移时原子失败；不调用 generic clone/copy/factory。
  protected function rdma_status snapshot_command_with_profile_locked(
    input rdma_cmq_command_desc source,
    input rdma_cmq_recovery_owner detached_owner,
    input rdma_cmq_nonfatal_snapshot_context context,
    input rdma_cmq_hw_profile profile_service,
    output rdma_cmq_command_desc snapshot
  );
    rdma_cmq_command_desc candidate;
    rdma_hw_model body_snapshot;
    rdma_handle function_snapshot_base;
    rdma_cmq_opcode_key opcode_snapshot;
    rdma_hw_image signature_snapshot;
    rdma_status status;

    snapshot = null;
    if (source == null || context == null || profile_service == null ||
        source.get_object_type() != rdma_cmq_command_desc::get_type())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal command source/context/profile is invalid"
      );

    status = profile_service.snapshot_command_body(
      source.body, body_snapshot
    );
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal command body snapshot returned null status"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    if (body_snapshot == null || body_snapshot == source.body ||
        !profile_service.same_command_body_value(
          source.body, body_snapshot
        ) || !profile_service.command_body_graph_detached(
          source.body, body_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal command body snapshot contract failed"
      );
    if (!rdma_cmq_try_snapshot_handle_direct(
          source.function_h, 1'b0, function_snapshot_base
        ) || !rdma_cmq_try_snapshot_opcode_key_direct(
          source.opcode_key, opcode_snapshot
        ) || !rdma_cmq_try_snapshot_image_direct(
          source.qpc_signature_source, 1'b1, signature_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal command shell nested snapshot failed"
      );
    if (detached_owner == null || detached_owner == source.recovery_owner ||
        !same_journal_owner_value(source.recovery_owner, detached_owner) ||
        source.timeout == 0)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal command owner or timeout is invalid"
      );

    candidate = new("journal_command_snapshot");
    if (!$cast(candidate.function_h, function_snapshot_base))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal command Function snapshot subtype is invalid"
      );
    candidate.opcode_key = opcode_snapshot;
    candidate.body = body_snapshot;
    candidate.qpc_signature_source = signature_snapshot;
    candidate.vfid_override = source.vfid_override;
    candidate.use_vfid = source.use_vfid;
    candidate.timeout = source.timeout;
    candidate.recovery_owner = detached_owner;
    if (candidate.function_h == source.function_h ||
        candidate.opcode_key == source.opcode_key ||
        (source.qpc_signature_source != null &&
         candidate.qpc_signature_source == source.qpc_signature_source) ||
        !candidate.function_h.same_instance(source.function_h) ||
        !same_opcode_value(candidate.opcode_key, source.opcode_key) ||
        (source.qpc_signature_source != null &&
         !same_image_value(candidate.qpc_signature_source,
                           source.qpc_signature_source)) ||
        candidate.vfid_override != source.vfid_override ||
        candidate.use_vfid != source.use_vfid ||
        candidate.timeout != source.timeout)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal command snapshot is unequal or aliased"
      );
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：用 engine 当前 profile 委托 command journal snapshot 的固定公开 seam。
  // 输入/输出及副作用：source/detached_owner/context 为输入，snapshot 为输出；
  //   本函数不取锁，调用方须已持 engine_lock 或处于串行 probe。
  // 失败/边界：当前 profile 缺失或 typed body/shell 拒绝时输出 null 与非空错误。
  protected function rdma_status snapshot_command_for_journal_locked(
    input rdma_cmq_command_desc source,
    input rdma_cmq_recovery_owner detached_owner,
    input rdma_cmq_nonfatal_snapshot_context context,
    output rdma_cmq_command_desc snapshot
  );
    return snapshot_command_with_profile_locked(
      source, detached_owner, context, profile, snapshot
    );
  endfunction

  // 功能：使用指定 profile 先复制可选 typed payload，再由 context 构造 completion shell。
  // 输入/输出及副作用：source/context/profile 为只读输入，snapshot 入口清空；
  //   ticket/status canonical aliases 由 context 维护。
  // 失败/边界：未知 payload、profile seam null/error、completion subtype/shape 或
  //   payload 分离验证失败时原子返回错误；null source/payload 按契约允许。
  protected function rdma_status snapshot_completion_with_profile_locked(
    input rdma_cmq_completion source,
    input rdma_cmq_nonfatal_snapshot_context context,
    input rdma_cmq_hw_profile profile_service,
    output rdma_cmq_completion snapshot
  );
    uvm_object payload_snapshot;
    rdma_cmq_completion candidate;
    rdma_cmq_completion canonical_source;
    rdma_hw_image canonical_raw_cqe;
    rdma_status status;
    string failure_reason;

    snapshot = null;
    if (context == null || profile_service == null)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ completion snapshot context or profile is null"
      );
    payload_snapshot = null;
    if (source != null && source.decoded_response != null) begin
      status = profile_service.snapshot_completion_payload(
        source.decoded_response, payload_snapshot
      );
      if (status == null)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ completion payload snapshot returned null status"
        );
      if (!status.ok())
        return journal_status(status.code, status.message);
      if (payload_snapshot == null ||
          payload_snapshot == source.decoded_response ||
          !profile_service.same_completion_payload_value(
            source.decoded_response, payload_snapshot
          ) || !profile_service.completion_payload_graph_detached(
            source.decoded_response, payload_snapshot
          ))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ completion payload snapshot contract failed"
        );
    end
    // 设计说明：poll 允许 profile/测试 factory 为 raw CQE 提供派生运行时
    //   subtype，但 retained journal 只接受 exact base image。这里直接投影
    //   已经通过 poll 认证的公开字段，避免再次调用 raw image factory/clone，
    //   也避免把 hostile subtype 泄漏到 detached journal graph。
    // 功能：为 completion snapshot 构造一个不经 factory 的 base raw-CQE
    //   输入壳；该壳仅供后续 nonfatal context 复制，不改变 source。
    // 输入/输出及副作用：source.raw_cqe 为只读输入，canonical_raw_cqe 为输出；
    //   复制 bytes、长度、对齐、端序、image/target metadata 和摘要，不修改
    //   source、profile 或 runtime ledger。
    // 失败/边界：硬件 completion 缺少 raw image、公开 shape 非法、字段投影
    //   前后不等或 canonical image 仍非 CMQ CQE 时返回 INVALID_ARGUMENT；
    //   timeout/reset completion 仍允许 null raw image。
    if (source != null && source.raw_cqe != null) begin
      canonical_raw_cqe = new("cmq_completion_canonical_raw_cqe");
      canonical_raw_cqe.bytes = source.raw_cqe.bytes;
      canonical_raw_cqe.length = source.raw_cqe.length;
      canonical_raw_cqe.alignment = source.raw_cqe.alignment;
      canonical_raw_cqe.endian = source.raw_cqe.endian;
      canonical_raw_cqe.image_kind = source.raw_cqe.image_kind;
      canonical_raw_cqe.hardware_version = source.raw_cqe.hardware_version;
      canonical_raw_cqe.function_generation =
        source.raw_cqe.function_generation;
      canonical_raw_cqe.write_target_kind =
        source.raw_cqe.write_target_kind;
      canonical_raw_cqe.backing_target = source.raw_cqe.backing_target;
      canonical_raw_cqe.hmc_target = source.raw_cqe.hmc_target;
      canonical_raw_cqe.bar_target = source.raw_cqe.bar_target;
      canonical_raw_cqe.field_summary = source.raw_cqe.field_summary;
      if (!rdma_cmq_image_shape_valid(canonical_raw_cqe) ||
          canonical_raw_cqe.length != CMQE_BYTES ||
          canonical_raw_cqe.image_kind != RDMA_IMAGE_CMQ_CQE ||
          canonical_raw_cqe.write_target_kind != RDMA_HW_TARGET_NONE ||
          canonical_raw_cqe.backing_target.value != 0 ||
          canonical_raw_cqe.hmc_target.value != 0 ||
          canonical_raw_cqe.bar_target.value != 0 ||
          source.ticket == null || source.ticket.function_h == null ||
          canonical_raw_cqe.function_generation !=
            source.ticket.function_h.generation ||
          !same_image_value(canonical_raw_cqe, source.raw_cqe))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ completion raw CQE canonicalization failed"
        );
    end
    if (source != null && canonical_raw_cqe != null) begin
      canonical_source = new("cmq_completion_canonical_source");
      canonical_source.ticket = source.ticket;
      canonical_source.status = source.status;
      canonical_source.raw_cqe = canonical_raw_cqe;
      canonical_source.decoded_response = source.decoded_response;
    end
    else
      canonical_source = source;
    if (!context.try_snapshot_completion_shell(
          canonical_source, payload_snapshot, candidate, failure_reason
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        {"CMQ completion shell snapshot failed: ", failure_reason}
      );
    if (source != null && (candidate == null || candidate == source))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ completion shell snapshot is null or aliased"
      );
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：用当前 engine profile 委托 completion result snapshot 的固定公开 seam。
  // 输入/输出及副作用：source/context 为输入，snapshot 为输出；不取锁或修改 profile。
  // 失败/边界：profile 缺失、未知 payload 或 shell 非法时输出 null 与非空错误。
  protected function rdma_status snapshot_completion_for_result_locked(
    input rdma_cmq_completion source,
    input rdma_cmq_nonfatal_snapshot_context context,
    output rdma_cmq_completion snapshot
  );
    return snapshot_completion_with_profile_locked(
      source, context, profile, snapshot
    );
  endfunction

  // 功能：为一次 runtime completion/timeout/late transition 只读定位唯一
  //   retained journal item，预建 journal-owned completion，并用 Task 9 reducer
  //   与 recovery classifier 计算完整目标标量；本函数不发布任何状态。
  // 输入/输出及副作用：slot_record/source_completion/target_state/target_phase
  //   为只读输入；成功返回 exact batch/item 非拥有句柄、独立 completion、
  //   recovery_required 与 reduced_batch_state，不修改 slot、FIFO 或 journal。
  // 失败/边界：locator 为空/越界、四表 invariant、ticket/slot/token 不等、
  //   非法前驱迁移、profile snapshot 或 reducer/classifier 失败时返回非 OK，
  //   所有输出清空；不从 request_index/current runtime 猜测 journal authority。
  protected function rdma_status stage_runtime_journal_transition_locked(
    input rdma_cmq_slot_record slot_record,
    input rdma_cmq_completion source_completion,
    input rdma_cmq_submission_state_e target_state,
    input rdma_cmq_completion_phase_e target_phase,
    output rdma_cmq_batch_submission_record batch_record,
    output rdma_cmq_batch_submission_item_record journal_item,
    output rdma_cmq_completion journal_completion,
    output bit recovery_required,
    output rdma_cmq_submission_state_e reduced_batch_state
  );
    rdma_cmq_nonfatal_snapshot_context snapshot_context;
    rdma_cmq_batch_submission_item_record reducer_items[$];
    rdma_cmq_batch_submission_item_record reducer_item;
    rdma_cmq_hw_profile retained_profile;
    rdma_status status;
    bit predecessor_valid;

    batch_record = null;
    journal_item = null;
    journal_completion = null;
    recovery_required = 1'b1;
    reduced_batch_state = RDMA_CMQ_SUBMISSION_STAGED;
    if (slot_record == null || source_completion == null ||
        slot_record.batch_key.len() == 0 ||
        !submission_journal.exists(slot_record.batch_key) ||
        !journal_profile_by_batch.exists(slot_record.batch_key))
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ runtime slot journal locator is missing or unknown"
      );
    status = submission_journal_invariant_locked(slot_record.batch_key);
    if (status == null || !status.ok())
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ runtime journal invariant returned null status"
      ) : journal_status(status.code, status.message);

    batch_record = submission_journal[slot_record.batch_key];
    retained_profile = journal_profile_by_batch[slot_record.batch_key];
    if (batch_record == null || retained_profile == null ||
        slot_record.journal_item_index >= batch_record.items.size()) begin
      batch_record = null;
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ runtime slot journal item index is out of range"
      );
    end
    journal_item = batch_record.items[slot_record.journal_item_index];
    if (journal_item == null || journal_item.ticket == null ||
        source_completion.ticket == null || source_completion.status == null ||
        !same_ticket_value(slot_record.ticket, journal_item.ticket) ||
        !same_ticket_value(source_completion.ticket, journal_item.ticket) ||
        journal_item.slot_sequence != slot_record.slot_sequence ||
        journal_item.slot_index != slot_record.sq_index ||
        journal_item.slot_wrap != slot_record.sq_wrap ||
        journal_item.command_token != slot_record.command_token ||
        journal_item.entry_key != entry_key(
          slot_record.sq_index, slot_record.sq_wrap
        )) begin
      batch_record = null;
      journal_item = null;
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ runtime slot and retained journal item disagree"
      );
    end

    predecessor_valid = 1'b0;
    case (target_state)
      RDMA_CMQ_SUBMISSION_COMPLETED,
      RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED:
        predecessor_valid = journal_item.state inside {
          RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
          RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
        } && journal_item.completion_phase == RDMA_CMQ_COMPLETION_PENDING &&
        journal_item.completion == null &&
        (target_phase == RDMA_CMQ_COMPLETION_TERMINAL ||
         target_phase == RDMA_CMQ_COMPLETION_TIMEOUT);
      RDMA_CMQ_SUBMISSION_LATE_COMPLETED:
        predecessor_valid = journal_item.state ==
                              RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED &&
                            journal_item.completion_phase ==
                              RDMA_CMQ_COMPLETION_TIMEOUT &&
                            journal_item.completion != null &&
                            target_phase ==
                              RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY;
      RDMA_CMQ_SUBMISSION_RESET_QUARANTINED:
        // Strict generation cancellation only owns a still-live published
        // predecessor.  A timeout tombstone is already terminal evidence and
        // remains quarantined until late completion or observed reset; the
        // reset candidate has a separate mutation-free path for that latter
        // transition.
        predecessor_valid = journal_item.state inside {
          RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
          RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
        } && journal_item.completion_phase == RDMA_CMQ_COMPLETION_PENDING &&
        journal_item.completion == null &&
        target_phase == RDMA_CMQ_COMPLETION_RESET_CANCELLED;
      default: predecessor_valid = 1'b0;
    endcase
    if (!predecessor_valid) begin
      batch_record = null;
      journal_item = null;
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ runtime journal lifecycle predecessor is invalid"
      );
    end

    snapshot_context = new();
    status = snapshot_completion_with_profile_locked(
      source_completion, snapshot_context, retained_profile,
      journal_completion
    );
    if (status == null) begin
      batch_record = null;
      journal_item = null;
      journal_completion = null;
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ runtime journal completion snapshot returned null status"
      );
    end
    if (!status.ok()) begin
      batch_record = null;
      journal_item = null;
      journal_completion = null;
      return journal_status(status.code, status.message);
    end
    if (journal_completion == null ||
        journal_completion.ticket == null ||
        journal_completion.status == null ||
        !same_ticket_value(journal_completion.ticket, journal_item.ticket)) begin
      batch_record = null;
      journal_item = null;
      journal_completion = null;
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ runtime journal completion snapshot is incomplete"
      );
    end
    status = rdma_cmq_classify_recovery_required(
      target_state, target_phase, journal_item.submission_effect, 1'b0,
      journal_item.recovery_owner.is_legacy_unmigrated(), recovery_required
    );
    if (status == null || !status.ok()) begin
      batch_record = null;
      journal_item = null;
      journal_completion = null;
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ runtime journal recovery classifier returned null status"
      ) : journal_status(status.code, status.message);
    end

    foreach (batch_record.items[i]) begin
      reducer_item = new($sformatf("cmq_lifecycle_reducer_item_%0d", i));
      reducer_item.state = (i == slot_record.journal_item_index) ?
        target_state : batch_record.items[i].state;
      reducer_items.push_back(reducer_item);
    end
    status = rdma_cmq_reduce_batch_state(
      reducer_items, reduced_batch_state
    );
    if (status == null || !status.ok()) begin
      batch_record = null;
      journal_item = null;
      journal_completion = null;
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ runtime journal reducer returned null status"
      ) : journal_status(status.code, status.message);
    end
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：把已完整 staging 的 lifecycle completion 与标量写入 exact retained
  //   item，并更新 reducer 产生的 batch aggregate；该提交只做句柄/标量赋值。
  // 输入/输出及副作用：batch_record/journal_item/journal_completion 为 engine-owned
  //   staged 句柄；target/recovery/reduced 为预计算值；成功同步更新 journal aliases。
  // 失败/边界：调用方必须先由 stage_runtime_journal_transition_locked() 认证；
  //   本函数无返回值、不分配、不调用外部服务，也不触碰 FIFO/runtime slot。
  protected function void commit_runtime_journal_transition_locked(
    input rdma_cmq_batch_submission_record batch_record,
    input rdma_cmq_batch_submission_item_record journal_item,
    input rdma_cmq_completion journal_completion,
    input rdma_cmq_submission_state_e target_state,
    input rdma_cmq_completion_phase_e target_phase,
    input bit recovery_required,
    input rdma_cmq_submission_state_e reduced_batch_state
  );
    journal_completion.ticket = journal_item.ticket;
    journal_item.status = journal_completion.status;
    journal_item.completion = journal_completion;
    journal_item.state = target_state;
    journal_item.completion_phase = target_phase;
    journal_item.reset_isolation_confirmed = 1'b0;
    journal_item.recovery_required = recovery_required;
    batch_record.state = reduced_batch_state;
  endfunction

  // 功能：在调用方的单一 context 中直接复制 reset proof 的 identity、tuple 与 owner 图。
  // 输入/输出及副作用：source/context 为输入，snapshot 入口清空；重算 proof_digest
  //   后才发布 candidate，重复 owner 复用同一 detached 节点。
  // 失败/边界：outer subtype、ID/key/state、tuple cardinality、owner/identity 或 digest
  //   任一无效时返回 INVALID_ARGUMENT/null；下游 null status 转 INVALID_STATE。
  protected function rdma_status snapshot_reset_proof_with_context_locked(
    input rdma_cmq_reset_isolation_proof source,
    input rdma_cmq_nonfatal_snapshot_context context,
    output rdma_cmq_reset_isolation_proof snapshot
  );
    rdma_cmq_reset_isolation_proof candidate;
    rdma_function_identity isolated_identity_snapshot;
    rdma_function_identity replacement_identity_snapshot;
    rdma_cmq_recovery_owner owner_snapshot;
    rdma_cmq_recovery_owner owners_snapshot[$];
    rdma_cmq_journal_digest_t computed_digest;
    rdma_status status;
    string failure_reason;

    snapshot = null;
    if (source == null || context == null ||
        source.get_object_type() != rdma_cmq_reset_isolation_proof::get_type())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof source or snapshot context is invalid"
      );
    if (source.proof_key.len() == 0 || source.batch_key.len() == 0 ||
        source.proof_id == 0 || source.batch_id == 0 ||
        source.attempt_id == 0 || source.engine_instance_id == 0 ||
        source.engine_incarnation == 0 || source.batch_digest == '0 ||
        source.proof_digest == '0 || !source.backing_release_confirmed ||
        !(source.state inside {RDMA_CMQ_RESET_PROOF_AWAITING_REBIND,
                               RDMA_CMQ_RESET_PROOF_READY}) ||
        source.isolated_request_indices.size() == 0 ||
        source.isolated_request_indices.size() !=
          source.isolated_image_digests.size() ||
        source.isolated_request_indices.size() !=
          source.isolated_authority_digests.size() ||
        source.isolated_request_indices.size() !=
          source.isolated_recovery_owners.size())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof fixed projection or tuple cardinality is invalid"
      );
    if ((source.state == RDMA_CMQ_RESET_PROOF_AWAITING_REBIND &&
         source.replacement_identity != null) ||
        (source.state == RDMA_CMQ_RESET_PROOF_READY &&
         (source.replacement_identity == null ||
          !source.replacement_identity.same_function(
            source.isolated_identity
          ) || source.replacement_identity.reset_epoch <=
            source.isolated_identity.reset_epoch)))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof replacement transition is invalid"
      );
    if (!rdma_cmq_try_snapshot_identity_direct(
          source.isolated_identity, isolated_identity_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof isolated identity snapshot failed"
      );
    replacement_identity_snapshot = null;
    if (source.replacement_identity != null &&
        !rdma_cmq_try_snapshot_identity_direct(
          source.replacement_identity, replacement_identity_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof replacement identity snapshot failed"
      );
    foreach (source.isolated_recovery_owners[i]) begin
      if (!context.try_snapshot_recovery_owner(
            source.isolated_recovery_owners[i], owner_snapshot,
            failure_reason
          ))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          {"CMQ reset proof owner snapshot failed: ", failure_reason}
        );
      owners_snapshot.push_back(owner_snapshot);
    end
    status = rdma_cmq_compute_reset_proof_digest(
      source.proof_key, source.proof_id, source.batch_key,
      source.batch_id, source.attempt_id, source.engine_instance_id,
      source.engine_incarnation, source.isolated_identity,
      source.batch_digest, source.isolated_request_indices,
      source.isolated_image_digests, source.isolated_authority_digests,
      source.isolated_recovery_owners, computed_digest
    );
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ reset proof digest computation returned null status"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    if (computed_digest != source.proof_digest)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof carried digest does not match its source graph"
      );

    candidate = new("journal_reset_proof_snapshot");
    candidate.proof_key = source.proof_key;
    candidate.proof_id = source.proof_id;
    candidate.batch_key = source.batch_key;
    candidate.batch_id = source.batch_id;
    candidate.attempt_id = source.attempt_id;
    candidate.engine_instance_id = source.engine_instance_id;
    candidate.engine_incarnation = source.engine_incarnation;
    candidate.isolated_identity = isolated_identity_snapshot;
    candidate.replacement_identity = replacement_identity_snapshot;
    candidate.batch_digest = source.batch_digest;
    candidate.isolated_request_indices = source.isolated_request_indices;
    candidate.isolated_image_digests = source.isolated_image_digests;
    candidate.isolated_authority_digests =
      source.isolated_authority_digests;
    candidate.isolated_recovery_owners = owners_snapshot;
    candidate.proof_digest = source.proof_digest;
    candidate.state = source.state;
    candidate.backing_release_confirmed =
      source.backing_release_confirmed;
    if (candidate == source ||
        candidate.isolated_identity == source.isolated_identity ||
        (source.replacement_identity != null &&
         candidate.replacement_identity == source.replacement_identity))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof snapshot retained a source graph alias"
      );
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：为 reset proof 公开 snapshot seam 创建唯一 direct-new context 并原子发布图。
  // 输入/输出及副作用：source 为只读输入，snapshot 入口清空；不登记 proof authority。
  // 失败/边界：任何 nested/digest 拒绝保持 output null，并返回稳定非空 status。
  protected function rdma_status snapshot_reset_proof_locked(
    input rdma_cmq_reset_isolation_proof source,
    output rdma_cmq_reset_isolation_proof snapshot
  );
    rdma_cmq_nonfatal_snapshot_context context;

    snapshot = null;
    context = new();
    return snapshot_reset_proof_with_context_locked(
      source, context, snapshot
    );
  endfunction

  // 功能：直接复制可选 command identity 标量，供 execution result 保留诊断身份。
  // 输入/输出及副作用：source 为输入，snapshot 入口清空；成功发布新 base 对象。
  // 失败/边界：null 按可选值成功；未知 subtype、无效文本/身份或值漂移原子失败。
  protected function rdma_status snapshot_journal_command_identity_locked(
    input rdma_cmq_command_identity source,
    output rdma_cmq_command_identity snapshot
  );
    rdma_cmq_command_identity candidate;

    snapshot = null;
    if (source == null)
      return journal_status(RDMA_SC_OK);
    if (source.get_object_type() != rdma_cmq_command_identity::get_type())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ command identity runtime subtype is unsupported"
      );
    candidate = new("journal_command_identity_snapshot");
    candidate.function_kind = source.function_kind;
    candidate.function_uid = source.function_uid;
    candidate.global_function_id = source.global_function_id;
    candidate.generation = source.generation;
    candidate.profile_name = source.profile_name;
    candidate.opcode = source.opcode;
    candidate.variant = source.variant;
    if (!same_journal_command_identity_value(source, candidate))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ command identity source is incomplete or changed"
      );
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：直接构造完整 execution result，并用一个 context 保留 ticket/status/owner alias。
  // 输入/输出及副作用：source 为只读输入，snapshot 入口清空；profile 仅复制
  //   completion typed payload，不参与 retry/proof/lifecycle authority。
  // 失败/边界：outer/nested subtype、profile payload seam 或 required status 失败时
  //   返回非空错误与 null；不调用 raw factory、generic clone/copy。
  protected function rdma_status snapshot_execution_result_locked(
    input rdma_cmq_execution_result source,
    output rdma_cmq_execution_result snapshot
  );
    rdma_cmq_nonfatal_snapshot_context context;
    rdma_cmq_execution_result candidate;
    rdma_cmq_ticket ticket_snapshot;
    rdma_cmq_completion completion_snapshot;
    rdma_status status_snapshot;
    rdma_status observation_snapshot;
    rdma_cmq_command_identity command_identity_snapshot;
    rdma_cmq_recovery_owner owner_snapshot;
    rdma_dma_request_context dma_snapshot;
    rdma_status status;
    string failure_reason;

    snapshot = null;
    if (source == null ||
        source.get_object_type() != rdma_cmq_execution_result::get_type())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ execution result source is null or unsupported"
      );
    context = new();
    if (!context.try_snapshot_optional_ticket(
          source.ticket, ticket_snapshot, failure_reason
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        {"CMQ execution result ticket snapshot failed: ", failure_reason}
      );
    status = snapshot_completion_with_profile_locked(
      source.completion, context, profile, completion_snapshot
    );
    if (status == null || !status.ok())
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ execution result completion snapshot returned null status"
      ) : journal_status(status.code, status.message);
    if (!context.try_snapshot_required_status(
          source.status, status_snapshot, failure_reason
        ) || !context.try_snapshot_required_status(
          source.observation_status, observation_snapshot, failure_reason
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        {"CMQ execution result status snapshot failed: ", failure_reason}
      );
    status = snapshot_journal_command_identity_locked(
      source.command_identity, command_identity_snapshot
    );
    if (status == null || !status.ok())
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ execution command identity snapshot returned null status"
      ) : journal_status(status.code, status.message);
    owner_snapshot = null;
    if (source.recovery_owner != null &&
        !context.try_snapshot_recovery_owner(
          source.recovery_owner, owner_snapshot, failure_reason
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        {"CMQ execution owner snapshot failed: ", failure_reason}
      );
    dma_snapshot = null;
    if (source.dma_context != null) begin
      status = snapshot_journal_dma_context_locked(
        source.dma_context, dma_snapshot
      );
      if (status == null || !status.ok())
        return (status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ execution DMA snapshot returned null status"
        ) : journal_status(status.code, status.message);
    end

    candidate = new("journal_execution_result_snapshot");
    candidate.ticket = ticket_snapshot;
    candidate.completion = completion_snapshot;
    candidate.status = status_snapshot;
    candidate.observation_status = observation_snapshot;
    candidate.command_identity = command_identity_snapshot;
    candidate.recovery_owner = owner_snapshot;
    candidate.dma_context = dma_snapshot;
    candidate.submission_effect = source.submission_effect;
    candidate.attempt_effect = source.attempt_effect;
    candidate.completion_phase = source.completion_phase;
    candidate.batch_key = source.batch_key;
    candidate.batch_id = source.batch_id;
    candidate.attempt_id = source.attempt_id;
    candidate.recovery_required = source.recovery_required;
    if (candidate == source ||
        (source.ticket != null && candidate.ticket == source.ticket) ||
        (source.completion != null &&
         candidate.completion == source.completion) ||
        candidate.status == source.status ||
        candidate.observation_status == source.observation_status ||
        (source.recovery_owner != null &&
         candidate.recovery_owner == source.recovery_owner))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ execution result snapshot retained a source alias"
      );
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：用指定 retained profile 和单一 context 直接复制完整 batch journal record。
  // 输入/输出及副作用：source/profile 为输入，snapshot 入口清空；成功 graph 拥有
  //   detached binding/handles/images/items，重复 ticket/status/owner 保持 canonical alias。
  // 失败/边界：required node/subtype、mapping opaque authority、typed body/payload 或
  //   alias topology 失败时不发布 partial record，返回具体非空 status。
  protected function rdma_status snapshot_journal_record_with_profile_locked(
    input rdma_cmq_batch_submission_record source,
    input rdma_cmq_hw_profile profile_service,
    output rdma_cmq_batch_submission_record snapshot
  );
    rdma_cmq_nonfatal_snapshot_context context;
    rdma_cmq_batch_submission_record candidate;
    rdma_function_identity identity_snapshot;
    rdma_function_binding binding_snapshot;
    rdma_handle cmq_snapshot;
    rdma_hw_image doorbell_snapshot;
    rdma_cmq_reset_isolation_proof proof_snapshot;
    rdma_dma_mapping mapping_snapshots[rdma_dma_mapping];
    rdma_status status;
    string failure_reason;

    snapshot = null;
    if (source == null || profile_service == null ||
        source.get_object_type() != rdma_cmq_batch_submission_record::get_type() ||
        source.function_identity == null || source.binding == null ||
        source.cmq_h == null || source.doorbell_image == null)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal record source or profile is null or unsupported"
      );
    if (source.batch_key.len() == 0 || source.batch_id == 0 ||
        source.attempt_id == 0 || source.engine_instance_id == 0 ||
        source.engine_incarnation == 0 || source.items.size() == 0)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal record fixed identity or item list is incomplete"
      );
    context = new();
    if (!rdma_cmq_try_snapshot_identity_direct(
          source.function_identity, identity_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal record Function identity snapshot failed"
      );
    status = source.binding.snapshot_complete_nonfatal(binding_snapshot);
    if (status == null || !status.ok() || binding_snapshot == null)
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal binding snapshot returned null status"
      ) : journal_status(status.code, status.message);
    if (!rdma_cmq_try_snapshot_handle_direct(
          source.cmq_h, 1'b0, cmq_snapshot
        ) || !rdma_cmq_try_snapshot_image_direct(
          source.doorbell_image, 1'b0, doorbell_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal record CMQ/doorbell snapshot failed"
      );

    candidate = new("journal_record_snapshot");
    candidate.batch_key = source.batch_key;
    candidate.batch_id = source.batch_id;
    candidate.attempt_id = source.attempt_id;
    candidate.engine_instance_id = source.engine_instance_id;
    candidate.engine_incarnation = source.engine_incarnation;
    candidate.function_identity = identity_snapshot;
    candidate.binding = binding_snapshot;
    candidate.cmq_h = cmq_snapshot;
    candidate.start_sequence = source.start_sequence;
    candidate.end_sequence = source.end_sequence;
    candidate.doorbell_image = doorbell_snapshot;
    candidate.final_pi = source.final_pi;
    candidate.final_polarity = source.final_polarity;
    candidate.batch_digest = source.batch_digest;
    candidate.state = source.state;
    candidate.submission_effect = source.submission_effect;
    candidate.attempt_effect = source.attempt_effect;
    candidate.observer_armed = source.observer_armed;
    candidate.publication_retry_safe = source.publication_retry_safe;

    foreach (source.items[i]) begin
      rdma_cmq_batch_submission_item_record source_item;
      rdma_cmq_batch_submission_item_record item_snapshot;
      rdma_cmq_recovery_owner owner_snapshot;
      rdma_cmq_command_desc command_snapshot;
      rdma_cmq_ticket ticket_snapshot;
      rdma_dma_request_context dma_snapshot;
      rdma_hw_image sqe_snapshot;
      rdma_dma_mapping mapping_snapshot;
      rdma_hw_image dependency_snapshot;
      rdma_cmq_completion completion_snapshot;
      rdma_status item_status_snapshot;

      source_item = source.items[i];
      if (source_item == null ||
          source_item.get_object_type() !=
            rdma_cmq_batch_submission_item_record::get_type() ||
          source_item.command == null || source_item.ticket == null ||
          source_item.recovery_owner == null ||
          source_item.command.recovery_owner !=
            source_item.recovery_owner ||
          source_item.dma_context == null || source_item.sqe_image == null ||
          source_item.dependency_mapping == null ||
          source_item.dependency_image == null || source_item.status == null)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf("CMQ journal item %0d graph is incomplete", i)
        );
      if (!context.try_snapshot_recovery_owner(
            source_item.recovery_owner, owner_snapshot, failure_reason
          ))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          {"CMQ journal owner snapshot failed: ", failure_reason}
        );
      status = snapshot_command_with_profile_locked(
        source_item.command, owner_snapshot, context, profile_service,
        command_snapshot
      );
      if (status == null || !status.ok())
        return (status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal command snapshot returned null status"
        ) : journal_status(status.code, status.message);
      if (!context.try_snapshot_optional_ticket(
            source_item.ticket, ticket_snapshot, failure_reason
          ) || ticket_snapshot == null)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          {"CMQ journal ticket snapshot failed: ", failure_reason}
        );
      status = snapshot_journal_dma_context_locked(
        source_item.dma_context, dma_snapshot
      );
      if (status == null || !status.ok())
        return (status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal DMA snapshot returned null status"
        ) : journal_status(status.code, status.message);
      if (!rdma_cmq_try_snapshot_image_direct(
            source_item.sqe_image, 1'b0, sqe_snapshot
          ) || !rdma_cmq_try_snapshot_image_direct(
            source_item.dependency_image, 1'b0, dependency_snapshot
          ))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ journal item image snapshot failed"
        );
      if (mapping_snapshots.exists(source_item.dependency_mapping)) begin
        mapping_snapshot =
          mapping_snapshots[source_item.dependency_mapping];
      end
      else begin
        status = snapshot_journal_mapping_locked(
          source_item.dependency_mapping, mapping_snapshot
        );
        if (status == null || !status.ok())
          return (status == null) ? journal_status(
            RDMA_SC_INVALID_STATE,
            "CMQ journal mapping snapshot returned null status"
          ) : journal_status(status.code, status.message);
        mapping_snapshots[source_item.dependency_mapping] =
          mapping_snapshot;
      end
      status = snapshot_completion_with_profile_locked(
        source_item.completion, context, profile_service,
        completion_snapshot
      );
      if (status == null || !status.ok())
        return (status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal completion snapshot returned null status"
        ) : journal_status(status.code, status.message);
      if (!context.try_snapshot_required_status(
            source_item.status, item_status_snapshot, failure_reason
          ))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          {"CMQ journal item status snapshot failed: ", failure_reason}
        );

      item_snapshot = new($sformatf("journal_item_snapshot_%0d", i));
      item_snapshot.request_index = source_item.request_index;
      item_snapshot.command = command_snapshot;
      item_snapshot.ticket = ticket_snapshot;
      item_snapshot.recovery_owner = owner_snapshot;
      item_snapshot.dma_context = dma_snapshot;
      item_snapshot.sqe_image = sqe_snapshot;
      item_snapshot.dependency_mapping = mapping_snapshot;
      item_snapshot.dependency_offset = source_item.dependency_offset;
      item_snapshot.dependency_image = dependency_snapshot;
      item_snapshot.slot_sequence = source_item.slot_sequence;
      item_snapshot.slot_index = source_item.slot_index;
      item_snapshot.slot_wrap = source_item.slot_wrap;
      item_snapshot.command_token = source_item.command_token;
      item_snapshot.token_incarnation = source_item.token_incarnation;
      item_snapshot.entry_key = source_item.entry_key;
      item_snapshot.image_digest = source_item.image_digest;
      item_snapshot.authority_digest = source_item.authority_digest;
      item_snapshot.dependency_replay_safe =
        source_item.dependency_replay_safe;
      item_snapshot.state = source_item.state;
      item_snapshot.submission_effect = source_item.submission_effect;
      item_snapshot.attempt_effect = source_item.attempt_effect;
      item_snapshot.completion_phase = source_item.completion_phase;
      item_snapshot.reset_isolation_confirmed =
        source_item.reset_isolation_confirmed;
      item_snapshot.recovery_required = source_item.recovery_required;
      item_snapshot.completion = completion_snapshot;
      item_snapshot.status = item_status_snapshot;
      if (item_snapshot.command.recovery_owner !=
            item_snapshot.recovery_owner ||
          (source_item.completion != null &&
           source_item.completion.ticket == source_item.ticket &&
           item_snapshot.completion.ticket != item_snapshot.ticket) ||
          (source_item.completion != null &&
           source_item.completion.status == source_item.status &&
           item_snapshot.completion.status != item_snapshot.status))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ journal item canonical alias topology changed"
        );
      candidate.items.push_back(item_snapshot);
    end

    proof_snapshot = null;
    if (source.reset_isolation_proof != null) begin
      status = snapshot_reset_proof_with_context_locked(
        source.reset_isolation_proof, context, proof_snapshot
      );
      if (status == null || !status.ok())
        return (status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal reset proof snapshot returned null status"
        ) : journal_status(status.code, status.message);
    end
    candidate.reset_isolation_proof = proof_snapshot;
    if (candidate == source || candidate.function_identity ==
          source.function_identity || candidate.binding == source.binding ||
        candidate.cmq_h == source.cmq_h ||
        candidate.doorbell_image == source.doorbell_image ||
        candidate.items.size() != source.items.size())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal record snapshot is partial or aliased"
      );
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：用当前 profile 建立 journal record detached snapshot 的固定公开 seam。
  // 输入/输出及副作用：source 为只读输入，snapshot 为输出；本函数不取锁。
  // 失败/边界：当前 profile 缺失或任一完整图门禁失败时保持 output null。
  protected function rdma_status snapshot_journal_record_locked(
    input rdma_cmq_batch_submission_record source,
    output rdma_cmq_batch_submission_record snapshot
  );
    return snapshot_journal_record_with_profile_locked(
      source, profile, snapshot
    );
  endfunction

  // 功能：直接复制 recovery request，并以当前 profile 重算每项与批次 digest 后发布。
  // 输入/输出及副作用：source 为只读输入，snapshot 入口清空；一个 direct-new
  //   context 保留 items/proof 中重复 ticket/owner，mapping 保留 opaque authority。
  // 失败/边界：固定字段、cardinality、profile name/body、carried digest、proof 或
  //   任一 nested snapshot 失败时输出 null；未知 polymorph 非致命返回 INVALID_ARGUMENT。
  protected function rdma_status snapshot_recovery_request_locked(
    input rdma_cmq_submission_recovery_request source,
    output rdma_cmq_submission_recovery_request snapshot
  );
    rdma_cmq_nonfatal_snapshot_context context;
    rdma_cmq_submission_recovery_request candidate;
    rdma_function_identity identity_snapshot;
    rdma_function_binding binding_snapshot;
    rdma_handle cmq_snapshot;
    rdma_hw_image doorbell_snapshot;
    rdma_cmq_reset_isolation_proof proof_snapshot;
    rdma_dma_mapping mapping_snapshots[rdma_dma_mapping];
    int unsigned request_indices[$];
    rdma_cmq_journal_digest_t image_digests[$];
    rdma_cmq_journal_digest_t authority_digests[$];
    rdma_cmq_journal_digest_t computed_batch_digest;
    rdma_status status;
    string profile_name;
    string failure_reason;

    snapshot = null;
    if (source == null || profile == null ||
        source.get_object_type() !=
          rdma_cmq_submission_recovery_request::get_type() ||
        source.batch_key.len() == 0 || source.batch_id == 0 ||
        source.expected_attempt_id == 0 ||
        source.expected_function_identity == null || source.binding == null ||
        source.cmq_h == null || source.doorbell_image == null ||
        source.items.size() == 0 ||
        !(source.action inside {RDMA_CMQ_RECOVERY_RETRY_PUBLISH,
                                RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION}))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request fixed projection is incomplete or unsupported"
      );
    profile_name = profile.profile_name();
    if (profile_name.len() == 0 ||
        rdma_cmq_string_has_separator(profile_name))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request profile name is invalid"
      );

    foreach (source.items[i]) begin
      rdma_cmq_submission_recovery_item source_item;
      rdma_cmq_journal_digest_t computed_image_digest;
      rdma_cmq_journal_digest_t computed_authority_digest;
      string body_tag;
      byte unsigned body_bytes[];

      source_item = source.items[i];
      if (source_item == null ||
          source_item.get_object_type() !=
            rdma_cmq_submission_recovery_item::get_type() ||
          source_item.command == null || source_item.ticket == null ||
          source_item.recovery_owner == null ||
          source_item.command.recovery_owner !=
            source_item.recovery_owner ||
          source_item.dma_context == null || source_item.sqe_image == null ||
          source_item.dependency_mapping == null ||
          source_item.dependency_image == null ||
          source_item.command.opcode_key == null ||
          source_item.ticket.opcode_key == null ||
          source_item.command.opcode_key.profile_name != profile_name ||
          source_item.ticket.opcode_key.profile_name != profile_name)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf("CMQ recovery request item %0d is incomplete", i)
        );
      status = profile.canonicalize_command_body(
        source_item.command.body, body_tag, body_bytes
      );
      if (status == null)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery request body canonicalization returned null status"
        );
      if (!status.ok())
        return journal_status(status.code, status.message);
      status = rdma_cmq_compute_item_digests(
        source_item.command, body_tag, body_bytes, source_item.ticket,
        source_item.recovery_owner, source.expected_function_identity,
        source_item.dma_context, source_item.sqe_image,
        source_item.dependency_mapping, source_item.dependency_offset,
        source_item.dependency_image, computed_image_digest,
        computed_authority_digest
      );
      if (status == null)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery request item digest returned null status"
        );
      if (!status.ok())
        return journal_status(status.code, status.message);
      if (computed_image_digest != source_item.image_digest ||
          computed_authority_digest != source_item.authority_digest)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery request item carried digest is inconsistent"
        );
      request_indices.push_back(source_item.request_index);
      image_digests.push_back(computed_image_digest);
      authority_digests.push_back(computed_authority_digest);
    end
    status = rdma_cmq_compute_batch_digest(
      source.expected_function_identity, source.binding, source.cmq_h,
      source.doorbell_image, source.final_pi, source.final_polarity,
      source.start_sequence, source.end_sequence, request_indices,
      image_digests, authority_digests, computed_batch_digest
    );
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery request batch digest returned null status"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    if (computed_batch_digest != source.batch_digest)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request carried batch digest is inconsistent"
      );

    context = new();
    if (!rdma_cmq_try_snapshot_identity_direct(
          source.expected_function_identity, identity_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request identity snapshot failed"
      );
    status = source.binding.snapshot_complete_nonfatal(binding_snapshot);
    if (status == null || !status.ok() || binding_snapshot == null)
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery request binding snapshot returned null status"
      ) : journal_status(status.code, status.message);
    if (!rdma_cmq_try_snapshot_handle_direct(
          source.cmq_h, 1'b0, cmq_snapshot
        ) || !rdma_cmq_try_snapshot_image_direct(
          source.doorbell_image, 1'b0, doorbell_snapshot
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request CMQ/doorbell snapshot failed"
      );

    candidate = new("journal_recovery_request_snapshot");
    candidate.batch_key = source.batch_key;
    candidate.batch_id = source.batch_id;
    candidate.expected_attempt_id = source.expected_attempt_id;
    candidate.expected_function_identity = identity_snapshot;
    candidate.binding = binding_snapshot;
    candidate.cmq_h = cmq_snapshot;
    candidate.start_sequence = source.start_sequence;
    candidate.end_sequence = source.end_sequence;
    candidate.doorbell_image = doorbell_snapshot;
    candidate.final_pi = source.final_pi;
    candidate.final_polarity = source.final_polarity;
    candidate.batch_digest = source.batch_digest;
    candidate.action = source.action;

    foreach (source.items[i]) begin
      rdma_cmq_submission_recovery_item source_item;
      rdma_cmq_submission_recovery_item item_snapshot;
      rdma_cmq_recovery_owner owner_snapshot;
      rdma_cmq_command_desc command_snapshot;
      rdma_cmq_ticket ticket_snapshot;
      rdma_dma_request_context dma_snapshot;
      rdma_hw_image sqe_snapshot;
      rdma_dma_mapping mapping_snapshot;
      rdma_hw_image dependency_snapshot;

      source_item = source.items[i];
      if (!context.try_snapshot_recovery_owner(
            source_item.recovery_owner, owner_snapshot, failure_reason
          ))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          {"CMQ recovery request owner snapshot failed: ", failure_reason}
        );
      status = snapshot_command_with_profile_locked(
        source_item.command, owner_snapshot, context, profile,
        command_snapshot
      );
      if (status == null || !status.ok())
        return (status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery request command snapshot returned null status"
        ) : journal_status(status.code, status.message);
      if (!context.try_snapshot_optional_ticket(
            source_item.ticket, ticket_snapshot, failure_reason
          ) || ticket_snapshot == null)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          {"CMQ recovery request ticket snapshot failed: ", failure_reason}
        );
      status = snapshot_journal_dma_context_locked(
        source_item.dma_context, dma_snapshot
      );
      if (status == null || !status.ok())
        return (status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery request DMA snapshot returned null status"
        ) : journal_status(status.code, status.message);
      if (!rdma_cmq_try_snapshot_image_direct(
            source_item.sqe_image, 1'b0, sqe_snapshot
          ) || !rdma_cmq_try_snapshot_image_direct(
            source_item.dependency_image, 1'b0, dependency_snapshot
          ))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery request image snapshot failed"
        );
      if (mapping_snapshots.exists(source_item.dependency_mapping)) begin
        mapping_snapshot =
          mapping_snapshots[source_item.dependency_mapping];
      end
      else begin
        status = snapshot_journal_mapping_locked(
          source_item.dependency_mapping, mapping_snapshot
        );
        if (status == null || !status.ok())
          return (status == null) ? journal_status(
            RDMA_SC_INVALID_STATE,
            "CMQ recovery request mapping snapshot returned null status"
          ) : journal_status(status.code, status.message);
        mapping_snapshots[source_item.dependency_mapping] =
          mapping_snapshot;
      end
      item_snapshot = new($sformatf(
        "journal_recovery_item_snapshot_%0d", i
      ));
      item_snapshot.request_index = source_item.request_index;
      item_snapshot.command = command_snapshot;
      item_snapshot.ticket = ticket_snapshot;
      item_snapshot.recovery_owner = owner_snapshot;
      item_snapshot.dma_context = dma_snapshot;
      item_snapshot.sqe_image = sqe_snapshot;
      item_snapshot.dependency_mapping = mapping_snapshot;
      item_snapshot.dependency_offset = source_item.dependency_offset;
      item_snapshot.dependency_image = dependency_snapshot;
      item_snapshot.image_digest = source_item.image_digest;
      item_snapshot.authority_digest = source_item.authority_digest;
      if (item_snapshot.command.recovery_owner !=
          item_snapshot.recovery_owner)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery request command/owner alias changed"
        );
      candidate.items.push_back(item_snapshot);
    end

    proof_snapshot = null;
    if (source.reset_isolation_proof != null) begin
      status = snapshot_reset_proof_with_context_locked(
        source.reset_isolation_proof, context, proof_snapshot
      );
      if (status == null || !status.ok())
        return (status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery request proof snapshot returned null status"
        ) : journal_status(status.code, status.message);
      if (source.reset_isolation_proof.batch_key != source.batch_key ||
          source.reset_isolation_proof.batch_id != source.batch_id ||
          source.reset_isolation_proof.attempt_id !=
            source.expected_attempt_id ||
          source.reset_isolation_proof.batch_digest != source.batch_digest)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery request reset proof does not identify this batch"
        );
    end
    candidate.reset_isolation_proof = proof_snapshot;
    if (candidate == source || candidate.expected_function_identity ==
          source.expected_function_identity ||
        candidate.binding == source.binding || candidate.cmq_h == source.cmq_h ||
        candidate.doorbell_image == source.doorbell_image ||
        candidate.items.size() != source.items.size())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request snapshot is partial or aliased"
      );
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：逐字段比较两个完整 Function binding 值，覆盖 identity、PCIe/BAR、
  //   notify、DMA/capability、vector、owner、lifecycle 与 readiness 投影。
  // 输入/输出及副作用：lhs/rhs 为只读输入；通过 nonfatal identity accessor
  //   取得 detached identity 后返回完整公开值是否一致，不修改任一 binding。
  // 失败/边界：null、非 base subtype、identity/BAR/owner 缺失或任一字段漂移
  //   返回 0；digest equality 不能替代本比较。
  protected function bit same_journal_binding_value(
    input rdma_function_binding lhs,
    input rdma_function_binding rhs
  );
    rdma_function_identity lhs_identity;
    rdma_function_identity rhs_identity;
    rdma_status lhs_status;
    rdma_status rhs_status;

    if (lhs == null || rhs == null ||
        lhs.get_object_type() != rdma_function_binding::get_type() ||
        rhs.get_object_type() != rdma_function_binding::get_type() ||
        lhs.pcie == null || rhs.pcie == null)
      return 1'b0;
    lhs_status = lhs.snapshot_identity_nonfatal(lhs_identity);
    rhs_status = rhs.snapshot_identity_nonfatal(rhs_identity);
    if (lhs_status == null || !lhs_status.ok() || rhs_status == null ||
        !rhs_status.ok() || lhs_identity == null || rhs_identity == null ||
        !lhs_identity.same_incarnation(rhs_identity) ||
        lhs.function_uid != rhs.function_uid ||
        lhs.pcie.bdf != rhs.pcie.bdf ||
        lhs.pcie.parent_pf_bdf != rhs.pcie.parent_pf_bdf ||
        lhs.pcie.vf_index != rhs.pcie.vf_index ||
        lhs.pcie.mse != rhs.pcie.mse || lhs.pcie.bme != rhs.pcie.bme ||
        lhs.notify_bar_id != rhs.notify_bar_id ||
        lhs.notify_base != rhs.notify_base ||
        lhs.notify_size != rhs.notify_size ||
        lhs.notify_table_sel != rhs.notify_table_sel ||
        lhs.notify_table_index != rhs.notify_table_index ||
        lhs.host_id != rhs.host_id || lhs.pfvf_id != rhs.pfvf_id ||
        lhs.rdma_vf_id != rhs.rdma_vf_id ||
        lhs.global_function_id != rhs.global_function_id ||
        lhs.vsi_id != rhs.vsi_id || lhs.queue_dma != rhs.queue_dma ||
        lhs.queue_caps != rhs.queue_caps ||
        lhs.interrupt_vectors.size() != rhs.interrupt_vectors.size() ||
        lhs.state != rhs.state || lhs.generation != rhs.generation ||
        lhs.notify_valid != rhs.notify_valid ||
        lhs.notify_ready != rhs.notify_ready ||
        lhs.dmi_valid != rhs.dmi_valid || lhs.dmi_ready != rhs.dmi_ready ||
        lhs.vft_valid != rhs.vft_valid || lhs.vft_ready != rhs.vft_ready ||
        ((lhs.owner_h == null) != (rhs.owner_h == null)))
      return 1'b0;
    if (lhs.owner_h != null &&
        (lhs.owner_h.get_object_type() != rhs.owner_h.get_object_type() ||
         !lhs.owner_h.same_instance(rhs.owner_h)))
      return 1'b0;
    foreach (lhs.pcie.bar[i]) begin
      if (lhs.pcie.bar[i] == null || rhs.pcie.bar[i] == null ||
          lhs.pcie.bar[i].bar_id != rhs.pcie.bar[i].bar_id ||
          lhs.pcie.bar[i].base != rhs.pcie.bar[i].base ||
          lhs.pcie.bar[i].size != rhs.pcie.bar[i].size ||
          lhs.pcie.bar[i].enabled != rhs.pcie.bar[i].enabled)
        return 1'b0;
    end
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
    return 1'b1;
  endfunction

  // 功能：比较 recovery request 与 journal item 的四个独立重算 digest，并在
  //   digest 全部可信后逐字段复验 command/body/owner/ticket/DMA/image/mapping。
  // 输入/输出及副作用：request_item、journal_item 与四个 recomputed digest
  //   均为只读输入；返回非空 status，不修改 graph、counter 或外部 adapter。
  // 失败/边界：carried/recomputed/cross-graph digest 不一致、command-owner alias
  //   破坏或任一完整值漂移返回 INVALID_ARGUMENT；null/partial graph 亦拒绝。
  protected function rdma_status validate_recovery_item_match_locked(
    input rdma_cmq_submission_recovery_item request_item,
    input rdma_cmq_batch_submission_item_record journal_item,
    input rdma_cmq_journal_digest_t recomputed_request_image_digest,
    input rdma_cmq_journal_digest_t recomputed_request_authority_digest,
    input rdma_cmq_journal_digest_t recomputed_journal_image_digest,
    input rdma_cmq_journal_digest_t recomputed_journal_authority_digest
  );
    if (request_item == null || journal_item == null ||
        request_item.command == null || journal_item.command == null ||
        request_item.ticket == null || journal_item.ticket == null ||
        request_item.recovery_owner == null ||
        journal_item.recovery_owner == null ||
        request_item.dma_context == null || journal_item.dma_context == null ||
        request_item.sqe_image == null || journal_item.sqe_image == null ||
        request_item.dependency_mapping == null ||
        journal_item.dependency_mapping == null ||
        request_item.dependency_image == null ||
        journal_item.dependency_image == null)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery item full-value graph is incomplete"
      );
    if (request_item.image_digest !== recomputed_request_image_digest ||
        request_item.authority_digest !==
          recomputed_request_authority_digest ||
        journal_item.image_digest !== recomputed_journal_image_digest ||
        journal_item.authority_digest !==
          recomputed_journal_authority_digest)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery item carried digest does not match its graph"
      );
    if (recomputed_request_image_digest !==
          recomputed_journal_image_digest ||
        recomputed_request_authority_digest !==
          recomputed_journal_authority_digest)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request and journal item digests disagree"
      );
    if (request_item.command.recovery_owner !=
          request_item.recovery_owner ||
        journal_item.command.recovery_owner !=
          journal_item.recovery_owner ||
        request_item.request_index != journal_item.request_index ||
        !same_handle(request_item.command.function_h,
                     journal_item.command.function_h) ||
        !same_opcode_value(request_item.command.opcode_key,
                           journal_item.command.opcode_key) ||
        !same_body_value(request_item.command.body,
                         journal_item.command.body) ||
        ((request_item.command.qpc_signature_source == null) !=
         (journal_item.command.qpc_signature_source == null)) ||
        (request_item.command.qpc_signature_source != null &&
         !same_image_value(request_item.command.qpc_signature_source,
                           journal_item.command.qpc_signature_source)) ||
        request_item.command.vfid_override !=
          journal_item.command.vfid_override ||
        request_item.command.use_vfid != journal_item.command.use_vfid ||
        request_item.command.timeout != journal_item.command.timeout ||
        !same_journal_owner_value(request_item.recovery_owner,
                                  journal_item.recovery_owner) ||
        !same_ticket_value(request_item.ticket, journal_item.ticket) ||
        !same_journal_dma_context_value(request_item.dma_context,
                                        journal_item.dma_context) ||
        !same_image_value(request_item.sqe_image,
                          journal_item.sqe_image) ||
        !same_journal_mapping_public_value(
          request_item.dependency_mapping,
          journal_item.dependency_mapping
        ) ||
        request_item.dependency_offset != journal_item.dependency_offset ||
        !same_image_value(request_item.dependency_image,
                          journal_item.dependency_image))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request and journal item full values disagree"
      );
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：在 batch digest 已分别重算后比较 request 与 journal 的完整固定值，
  //   包括 Function/binding/CMQ/doorbell/PI/polarity/sequence 与有序 item tuple。
  // 输入/输出及副作用：request、journal_record 和两个 recomputed batch digest
  //   为只读输入；只返回 status，不检查 mutable lifecycle 或执行恢复动作。
  // 失败/边界：carried/recomputed/cross-graph digest、cardinality/order 或任一
  //   完整字段不一致返回 INVALID_ARGUMENT；不把 hash equality 当 authority。
  protected function rdma_status validate_recovery_batch_match_locked(
    input rdma_cmq_submission_recovery_request request,
    input rdma_cmq_batch_submission_record journal_record,
    input rdma_cmq_journal_digest_t recomputed_request_batch_digest,
    input rdma_cmq_journal_digest_t recomputed_journal_batch_digest
  );
    if (request == null || journal_record == null ||
        request.expected_function_identity == null ||
        journal_record.function_identity == null || request.binding == null ||
        journal_record.binding == null || request.cmq_h == null ||
        journal_record.cmq_h == null || request.doorbell_image == null ||
        journal_record.doorbell_image == null || request.items.size() == 0 ||
        request.items.size() != journal_record.items.size())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery batch full-value graph is incomplete"
      );
    if (request.batch_digest !== recomputed_request_batch_digest ||
        journal_record.batch_digest !== recomputed_journal_batch_digest)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery batch carried digest does not match its graph"
      );
    if (recomputed_request_batch_digest !==
        recomputed_journal_batch_digest)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request and journal batch digests disagree"
      );
    if (request.batch_key != journal_record.batch_key ||
        request.batch_id != journal_record.batch_id ||
        !request.expected_function_identity.same_incarnation(
          journal_record.function_identity
        ) || !same_journal_binding_value(request.binding,
                                          journal_record.binding) ||
        !same_handle(request.cmq_h, journal_record.cmq_h) ||
        !same_image_value(request.doorbell_image,
                          journal_record.doorbell_image) ||
        request.final_pi != journal_record.final_pi ||
        request.final_polarity != journal_record.final_polarity ||
        request.start_sequence != journal_record.start_sequence ||
        request.end_sequence != journal_record.end_sequence)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request and journal batch full values disagree"
      );
    foreach (request.items[i]) begin
      if (request.items[i] == null || journal_record.items[i] == null ||
          request.items[i].request_index !=
            journal_record.items[i].request_index ||
          request.items[i].image_digest !==
            journal_record.items[i].image_digest ||
          request.items[i].authority_digest !==
            journal_record.items[i].authority_digest)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery batch ordered item tuple disagrees"
        );
    end
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：为 recovery staging 直接构造 fail-closed execution result outer 值。
  // 输入/输出及副作用：name 仅作为新对象名；返回调用方拥有的 result，不查询
  //   journal、factory 或外部 service。
  // 失败/边界：production direct-new 始终非空；virtual seam 允许测试在 CAS 前
  //   注入 null，调用方必须发布 emergency aligned fallback。
  protected virtual function rdma_cmq_execution_result
  make_recovery_result_locked(input string name);
    rdma_cmq_execution_result result;

    result = new(name);
    return result;
  endfunction

  // 功能：为 recovery result staging 创建 frozen owner 的 detached 完整值。
  // 输入/输出及副作用：name/source 为只读输入；成功返回新 owner，不修改 source
  //   或 authoritative journal。
  // 失败/边界：source null、legacy 以外的坏 shape 或 nested snapshot 失败返回 null；
  //   virtual seam 只用于 CAS 前候选构造故障测试。
  protected virtual function rdma_cmq_recovery_owner
  make_recovery_owner_locked(
    input string name,
    input rdma_cmq_recovery_owner source
  );
    rdma_cmq_nonfatal_snapshot_context context;
    rdma_cmq_recovery_owner snapshot;
    string failure_reason;

    context = new();
    if (!context.try_snapshot_recovery_owner(
          source, snapshot, failure_reason
        ))
      return null;
    snapshot.set_name(name);
    return snapshot;
  endfunction

  // 功能：为 recovery descriptor staging 直接构造空 doorbell outer 值。
  // 输入/输出及副作用：name 只命名候选；返回调用方拥有的新 descriptor，
  //   不调用 scheduler 或修改 attempt counter。
  // 失败/边界：production direct-new 始终非空；virtual seam 可在唯一 CAS 前
  //   注入 null，调用方须保持 retained authority 不变。
  protected virtual function rdma_doorbell_desc
  make_recovery_doorbell_locked(input string name);
    rdma_doorbell_desc doorbell;

    doorbell = new(name);
    return doorbell;
  endfunction

  // 功能：为 candidate attempt 直接构造尚未配置的一次性 MMIO observer。
  // 输入/输出及副作用：name 只命名候选；返回独立 observer，不登记 capability。
  // 失败/边界：production direct-new 始终非空；virtual seam 可返回 null 或已配置
  //   对象以覆盖 configure 失败，任何失败都必须发生在 CAS/I/O 前。
  protected virtual function rdma_cmq_mmio_arm_observer
  make_recovery_observer_locked(input string name);
    rdma_cmq_mmio_arm_observer observer;

    observer = new(name);
    return observer;
  endfunction

  // 功能：用指定 profile 对 record 的 immutable digest 与 mutable lifecycle evidence
  //   执行同一份完整 invariant，区分首次安装和合法 retry 后的 attempt 关系。
  // 输入/输出及副作用：source/profile_service/initial_install 为只读输入；调用
  //   profile canonicalize body，重算 item/batch digest、batch state 与 recovery bit。
  // 失败/边界：key/shape/enum/reducer/classifier、owner attempt、required completion
  //   alias、polymorph 或 digest 任一不一致返回非空失败；不修改 source 或 journal。
  protected function rdma_status validate_submission_record_locked(
    input rdma_cmq_batch_submission_record source,
    input rdma_cmq_hw_profile profile_service,
    input bit initial_install
  );
    string expected_batch_key;
    string format_failure;
    string service_name;
    bit key_formatted;
    bit request_seen[int unsigned];
    bit ticket_seen[string];
    int unsigned request_indices[$];
    rdma_cmq_journal_digest_t image_digests[$];
    rdma_cmq_journal_digest_t authority_digests[$];
    rdma_cmq_journal_digest_t computed_batch_digest;
    rdma_cmq_submission_state_e reduced_batch_state;
    rdma_status status;

    if (source == null || profile_service == null ||
        source.get_object_type() != rdma_cmq_batch_submission_record::get_type() ||
        source.function_identity == null || source.binding == null ||
        source.cmq_h == null || source.doorbell_image == null ||
        source.batch_key.len() == 0 || source.batch_id == 0 ||
        source.attempt_id == 0 || source.engine_instance_id == 0 ||
        source.engine_incarnation == 0 || source.items.size() == 0 ||
        source.start_sequence >= source.end_sequence ||
        source.end_sequence - source.start_sequence != source.items.size())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal record fixed projection is incomplete or inconsistent"
      );
    if (source.engine_instance_id != engine_instance_id)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal record belongs to a different engine instance"
      );
    key_formatted = rdma_cmq_format_batch_key(
      source.function_identity, source.engine_instance_id,
      source.engine_incarnation, source.batch_id, expected_batch_key,
      format_failure
    );
    if (!key_formatted || expected_batch_key != source.batch_key)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        key_formatted ? "CMQ journal batch key is not canonical" :
                        {"CMQ journal batch key formatting failed: ",
                         format_failure}
      );
    service_name = profile_service.profile_name();
    if (service_name.len() == 0 ||
        rdma_cmq_string_has_separator(service_name))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal retained profile name is invalid"
      );
    if (!rdma_cmq_submission_state_valid(source.state) ||
        !rdma_cmq_submission_effect_valid(source.submission_effect) ||
        !rdma_cmq_submission_effect_valid(source.attempt_effect))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal batch mutable evidence contains an invalid enum"
      );

    foreach (source.items[i]) begin
      rdma_cmq_batch_submission_item_record item;
      rdma_cmq_journal_digest_t computed_image_digest;
      rdma_cmq_journal_digest_t computed_authority_digest;
      bit classified_recovery_required;
      string body_tag;
      byte unsigned body_bytes[];
      string ticket_key;

      item = source.items[i];
      if (item == null ||
          item.get_object_type() !=
            rdma_cmq_batch_submission_item_record::get_type() ||
          item.command == null || item.ticket == null ||
          item.recovery_owner == null ||
          item.command.recovery_owner != item.recovery_owner ||
          item.dma_context == null || item.sqe_image == null ||
          item.dependency_mapping == null || item.dependency_image == null ||
          item.status == null || item.command.opcode_key == null ||
          item.ticket.opcode_key == null || item.entry_key.len() == 0 ||
          item.command.opcode_key.profile_name != service_name ||
          item.ticket.opcode_key.profile_name != service_name ||
          item.slot_sequence != item.ticket.slot_sequence ||
          item.slot_index != item.ticket.sq_index ||
          item.slot_wrap != item.ticket.sq_wrap ||
          item.token_incarnation != source.engine_incarnation[58:0])
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf("CMQ journal item %0d projection is incomplete", i)
        );
      if (!rdma_cmq_submission_state_valid(item.state) ||
          !rdma_cmq_submission_effect_valid(item.submission_effect) ||
          !rdma_cmq_submission_effect_valid(item.attempt_effect) ||
          !rdma_cmq_completion_phase_valid(item.completion_phase))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf(
            "CMQ journal item %0d mutable evidence has an invalid enum", i
          )
        );
      if (!rdma_cmq_frozen_owner_shape_valid(item.recovery_owner))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf("CMQ journal item %0d recovery owner is invalid", i)
        );
      if (!item.recovery_owner.is_legacy_unmigrated() &&
          (item.recovery_owner.admission_attempt_id > source.attempt_id ||
           (initial_install &&
            item.recovery_owner.admission_attempt_id != source.attempt_id)))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf(
            "CMQ journal item %0d owner attempt is not valid for the batch",
            i
          )
        );
      if (item.completion_phase inside {
            RDMA_CMQ_COMPLETION_TERMINAL,
            RDMA_CMQ_COMPLETION_TIMEOUT,
            RDMA_CMQ_COMPLETION_RESET_CANCELLED,
            RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY
          } && item.completion == null)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf("CMQ journal item %0d requires a completion", i)
        );
      if (item.completion != null &&
          (item.completion.ticket != item.ticket ||
           item.completion.status != item.status))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf(
            "CMQ journal item %0d completion aliases are inconsistent", i
          )
        );
      status = rdma_cmq_classify_recovery_required(
        item.state, item.completion_phase, item.submission_effect,
        item.reset_isolation_confirmed,
        item.recovery_owner.is_legacy_unmigrated(),
        classified_recovery_required
      );
      if (status == null)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ journal recovery classifier returned null status"
        );
      if (!status.ok())
        return journal_status(RDMA_SC_INVALID_ARGUMENT, status.message);
      if (classified_recovery_required != item.recovery_required)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf(
            "CMQ journal item %0d recovery classification disagrees", i
          )
        );
      if (request_seen.exists(item.request_index))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ journal record contains a duplicate request index"
        );
      request_seen[item.request_index] = 1'b1;
      if (!rdma_cmq_ticket_shape_valid(item.ticket))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ journal record contains an invalid ticket"
        );
      ticket_key = command_key(item.ticket);
      if (ticket_key.len() == 0 || ticket_seen.exists(ticket_key))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ journal record contains a duplicate or empty ticket key"
        );
      ticket_seen[ticket_key] = 1'b1;
      status = profile_service.canonicalize_command_body(
        item.command.body, body_tag, body_bytes
      );
      if (status == null)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal body canonicalization returned null status"
        );
      if (!status.ok())
        return journal_status(status.code, status.message);
      status = rdma_cmq_compute_item_digests(
        item.command, body_tag, body_bytes, item.ticket,
        item.recovery_owner, source.function_identity, item.dma_context,
        item.sqe_image, item.dependency_mapping, item.dependency_offset,
        item.dependency_image, computed_image_digest,
        computed_authority_digest
      );
      if (status == null)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal item digest computation returned null status"
        );
      if (!status.ok())
        return journal_status(status.code, status.message);
      if (computed_image_digest != item.image_digest ||
          computed_authority_digest != item.authority_digest)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ journal item carried digest does not match its graph"
        );
      request_indices.push_back(item.request_index);
      image_digests.push_back(computed_image_digest);
      authority_digests.push_back(computed_authority_digest);
    end
    status = rdma_cmq_reduce_batch_state(source.items, reduced_batch_state);
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal batch state reducer returned null status"
      );
    if (!status.ok())
      return journal_status(RDMA_SC_INVALID_ARGUMENT, status.message);
    if (reduced_batch_state != source.state)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal batch state disagrees with its item reduction"
      );
    status = rdma_cmq_compute_batch_digest(
      source.function_identity, source.binding, source.cmq_h,
      source.doorbell_image, source.final_pi, source.final_polarity,
      source.start_sequence, source.end_sequence, request_indices,
      image_digests, authority_digests, computed_batch_digest
    );
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal batch digest computation returned null status"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    if (computed_batch_digest != source.batch_digest)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal carried batch digest does not match its graph"
      );
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：验证并直接复制与 detached record 一一对应的预分配发布批次。
  // 输入/输出及副作用：source、source_record、record_snapshot 为输入，snapshot
  //   入口清空；成功复用 record_snapshot ticket 以维持 engine-owned alias。
  // 失败/边界：批次/SQE-CQE 格式/cardinality、slot/key/token 或 expected-response
  //   任一 partial/漂移时返回 INVALID_ARGUMENT/null；doorbell 使用独立 codec 格式，
  //   已由 record 校验与 digest 约束，不与 profile 的 SQE/CQE 格式强制相等。
  protected function rdma_status snapshot_preallocated_publish_batch_locked(
    input rdma_cmq_preallocated_publish_batch source,
    input rdma_cmq_batch_submission_record source_record,
    input rdma_cmq_batch_submission_record record_snapshot,
    output rdma_cmq_preallocated_publish_batch snapshot
  );
    rdma_cmq_preallocated_publish_batch candidate;

    snapshot = null;
    if (source == null || source_record == null || record_snapshot == null ||
        source.get_object_type() !=
          rdma_cmq_preallocated_publish_batch::get_type() ||
        source.batch_key != source_record.batch_key ||
        source.batch_key != record_snapshot.batch_key ||
        source.attempt_id != source_record.attempt_id ||
        source.final_sequence != source_record.end_sequence ||
        !source.profile_format_valid ||
        !(source.profile_endian inside {RDMA_ENDIAN_LITTLE,
                                        RDMA_ENDIAN_BIG}) ||
        source.profile_hardware_version == 0 ||
        source.items.size() != source_record.items.size() ||
        record_snapshot.items.size() != source_record.items.size())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ preallocated publication batch is incomplete or inconsistent"
      );
    candidate = new("journal_preallocated_batch_snapshot");
    candidate.batch_key = source.batch_key;
    candidate.attempt_id = source.attempt_id;
    candidate.final_sequence = source.final_sequence;
    candidate.profile_format_valid = source.profile_format_valid;
    candidate.profile_endian = source.profile_endian;
    candidate.profile_hardware_version =
      source.profile_hardware_version;
    foreach (source.items[i]) begin
      rdma_cmq_preallocated_publish_item source_item;
      rdma_cmq_preallocated_publish_item item_snapshot;
      rdma_cmq_slot_record slot_snapshot;
      rdma_cmq_expected_response expected_snapshot;

      source_item = source.items[i];
      if (source_item == null || source_record.items[i] == null ||
          record_snapshot.items[i] == null ||
          source_item.get_object_type() !=
            rdma_cmq_preallocated_publish_item::get_type() ||
          source_item.slot_record == null ||
          source_item.slot_record.get_object_type() !=
            rdma_cmq_slot_record::get_type() ||
          source_item.slot_record.ticket == null ||
          source_item.slot_record.expected == null ||
          source_item.slot_record.expected.get_object_type() !=
            rdma_cmq_expected_response::get_type() ||
          source_item.request_index !=
            source_record.items[i].request_index ||
          !same_ticket_value(source_item.slot_record.ticket,
                             source_record.items[i].ticket) ||
          source_item.slot_record.slot_sequence !=
            source_record.items[i].slot_sequence ||
          source_item.slot_record.sq_index !=
            source_record.items[i].slot_index ||
          source_item.slot_record.sq_wrap !=
            source_record.items[i].slot_wrap ||
          source_item.slot_record.state != CMQ_SLOT_PUBLISHED ||
          source_item.slot_record.command_token !=
            source_record.items[i].command_token ||
          source_item.slot_record.batch_key != source_record.batch_key ||
          source_item.slot_record.journal_item_index != i ||
          source_item.command_key != command_key(
            source_record.items[i].ticket
          ) || source_item.entry_key != source_record.items[i].entry_key ||
          source_item.command_token !=
            source_record.items[i].command_token ||
          source_record.items[i].sqe_image.endian !=
            source.profile_endian ||
          source_record.items[i].sqe_image.hardware_version !=
            source.profile_hardware_version ||
          source_record.items[i].dependency_image.endian !=
            source.profile_endian ||
          source_record.items[i].dependency_image.hardware_version !=
            source.profile_hardware_version)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          $sformatf("CMQ preallocated publication item %0d is partial", i)
        );
      expected_snapshot = new($sformatf(
        "journal_preallocated_expected_%0d", i
      ));
      expected_snapshot.hardware_opcode =
        source_item.slot_record.expected.hardware_opcode;
      expected_snapshot.variant = source_item.slot_record.expected.variant;
      if (expected_snapshot.variant.len() == 0 ||
          rdma_cmq_string_has_separator(expected_snapshot.variant))
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ preallocated expected response is invalid"
        );
      slot_snapshot = new($sformatf(
        "journal_preallocated_slot_%0d", i
      ));
      slot_snapshot.slot_sequence = source_item.slot_record.slot_sequence;
      slot_snapshot.sq_index = source_item.slot_record.sq_index;
      slot_snapshot.sq_wrap = source_item.slot_record.sq_wrap;
      slot_snapshot.state = source_item.slot_record.state;
      slot_snapshot.ticket = record_snapshot.items[i].ticket;
      slot_snapshot.expected = expected_snapshot;
      slot_snapshot.command_token = source_item.slot_record.command_token;
      slot_snapshot.batch_key = source_item.slot_record.batch_key;
      slot_snapshot.journal_item_index =
        source_item.slot_record.journal_item_index;
      item_snapshot = new($sformatf(
        "journal_preallocated_item_%0d", i
      ));
      item_snapshot.request_index = source_item.request_index;
      item_snapshot.slot_record = slot_snapshot;
      item_snapshot.command_key = source_item.command_key;
      item_snapshot.entry_key = source_item.entry_key;
      item_snapshot.command_token = source_item.command_token;
      candidate.items.push_back(item_snapshot);
    end
    snapshot = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：检查指定 key 的 record/profile 主行是否同生同在，并区分 arm 前/后
  //   preallocation 生命周期：未 arm record 必须有预分配行，已 arm record 可已消费。
  // 输入/输出及副作用：batch_key 为输入，row_set_present 为输出；只读
  //   record/preallocation/profile，成功以 0/1 区分完整缺席和完整存在。
  // 失败/边界：空 key 返回 INVALID_ARGUMENT；record/profile 孤行、null 行、
  //   无 record 的 preallocation，或 observer_armed=0 却缺 preallocation 返回 INVALID_STATE。
  protected function rdma_status journal_row_set_existence_locked(
    input string batch_key,
    output bit row_set_present
  );
    bit record_present;
    bit preallocation_present;
    bit profile_present;

    row_set_present = 1'b0;
    if (batch_key.len() == 0)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT, "CMQ journal batch key is empty"
      );
    record_present = submission_journal.exists(batch_key);
    preallocation_present = preallocated_publish_batches.exists(batch_key);
    profile_present = journal_profile_by_batch.exists(batch_key);
    if (record_present != profile_present)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal record/profile rows are orphaned"
      );
    if (!record_present) begin
      if (preallocation_present)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal preallocation row is orphaned"
        );
      return journal_status(RDMA_SC_OK);
    end
    if (submission_journal[batch_key] == null ||
        journal_profile_by_batch[batch_key] == null ||
        (preallocation_present &&
         preallocated_publish_batches[batch_key] == null))
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal record/preallocation/profile row contains null"
      );
    // preallocation 只在首次 arm/retry 的 pre-MMIO 窗口提供 runtime 安装值。
    // 一旦 completion/timeout/late/reset 已把证据写入 retained item，reset
    // commit 会有意删除旧 runtime/preallocation；这些终态仍必须可查询。
    if (!preallocation_present &&
        !submission_journal[batch_key].observer_armed &&
        submission_journal[batch_key].state inside {
          RDMA_CMQ_SUBMISSION_STAGED,
          RDMA_CMQ_SUBMISSION_PENDING_EFFECT,
          RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED
        })
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ unarmed journal record has no preallocation row"
      );
    row_set_present = 1'b1;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：全局确认每条 ticket index 都指向一组完整、非空的 retained 主表行。
  // 输入/输出及副作用：无输入；遍历 journal_batch_by_ticket 并只读三张主表，
  //   返回直接构造的 status，不形成 ticket key 或修改任何 retained 状态。
  // 失败/边界：空 index/target、目标主表缺失、部分存在、null 行或 helper null
  //   status 均返回 INVALID_STATE；空 index 表是合法状态。
  protected function rdma_status journal_ticket_index_targets_locked();
    bit target_present;
    rdma_status status;

    foreach (journal_batch_by_ticket[ticket_key]) begin
      string target_batch_key;

      target_batch_key = journal_batch_by_ticket[ticket_key];
      if (ticket_key.len() == 0 || target_batch_key.len() == 0)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal ticket index contains an empty key or target"
        );
      status = journal_row_set_existence_locked(
        target_batch_key, target_present
      );
      if (status == null)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal ticket target check returned null status"
        );
      if (!status.ok() || !target_present)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          status.ok() ?
            "CMQ journal ticket index targets a missing row set" :
            status.message
        );
    end
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：检查一个 batch 的 record/ticket-index/preallocation/profile 四表一致性。
  // 输入/输出及副作用：batch_key 为输入；先全局审计 index target，再只读该
  //   batch 的完整主表与每个 retained ticket，始终在 key 形成前验证 ticket shape。
  // 失败/边界：完整缺失返回 INVALID_ARGUMENT；orphan/null/坏 ticket、索引路由或
  //   cardinality 不一致返回 INVALID_STATE，不触发 null-object access 或自动修复。
  protected function rdma_status submission_journal_invariant_locked(
    input string batch_key
  );
    rdma_cmq_batch_submission_record record;
    bit row_set_present;
    int unsigned indexed_count;
    rdma_status status;

    if (batch_key.len() == 0)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT, "CMQ journal batch key is not present"
      );
    status = journal_ticket_index_targets_locked();
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket target invariant returned null status"
      );
    if (!status.ok())
      return journal_status(RDMA_SC_INVALID_STATE, status.message);
    status = journal_row_set_existence_locked(batch_key, row_set_present);
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal row-set invariant returned null status"
      );
    if (!status.ok())
      return journal_status(RDMA_SC_INVALID_STATE, status.message);
    if (!row_set_present)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT, "CMQ journal batch key is not present"
      );
    record = submission_journal[batch_key];
    if (record == null || record.batch_key != batch_key)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal batch row is inconsistent"
      );
    if (preallocated_publish_batches.exists(batch_key) &&
        (preallocated_publish_batches[batch_key].batch_key != batch_key ||
         preallocated_publish_batches[batch_key].items.size() !=
           record.items.size()))
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal preallocation row is inconsistent"
      );
    foreach (record.items[i]) begin
      string ticket_key;

      if (record.items[i] == null ||
          !rdma_cmq_ticket_shape_valid(record.items[i].ticket))
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal retained item or ticket shape is invalid"
        );
      ticket_key = command_key(record.items[i].ticket);
      if (!journal_batch_by_ticket.exists(ticket_key) ||
          journal_batch_by_ticket[ticket_key] != batch_key)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal retained ticket index is missing or misrouted"
        );
    end
    indexed_count = 0;
    foreach (journal_batch_by_ticket[ticket_key]) begin
      if (journal_batch_by_ticket[ticket_key] == batch_key)
        indexed_count++;
    end
    if (indexed_count != record.items.size())
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal retained ticket index cardinality is inconsistent"
      );
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：在锁内为当前 engine incarnation 分配下一个非零 batch ID 与 canonical key。
  // 输入/输出及副作用：identity 为输入，batch_key/batch_id 入口清空；成功才推进
  //   batch_id_counter，不安装 journal 行。
  // 失败/边界：identity/engine/incarnation 无效、counter 耗尽、formatter 或四表 key
  //   冲突时输出保持空/零且 counter 不变。
  protected function rdma_status allocate_batch_identity_locked(
    input rdma_function_identity identity,
    output string batch_key,
    output longint unsigned batch_id
  );
    longint unsigned candidate_id;
    bit row_set_present;
    string candidate_key;
    string failure_reason;
    rdma_status status;

    batch_key = "";
    batch_id = 0;
    if (engine_instance_id == 0 || engine_incarnation == 0 ||
        identity == null ||
        identity.get_object_type() != rdma_function_identity::get_type() ||
        !rdma_cmq_identity_shape_valid(identity))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ batch allocation identity or engine incarnation is invalid"
      );
    if (batch_id_counter == 64'hffff_ffff_ffff_ffff)
      return journal_status(
        RDMA_SC_RESOURCE_EXHAUSTED, "CMQ batch IDs are exhausted"
      );
    candidate_id = batch_id_counter + 1'b1;
    if (!rdma_cmq_format_batch_key(
          identity, engine_instance_id, engine_incarnation, candidate_id,
          candidate_key, failure_reason
        ))
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        {"CMQ batch key allocation failed: ", failure_reason}
      );
    status = journal_ticket_index_targets_locked();
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ batch allocation ticket target check returned null status"
      );
    if (!status.ok())
      return journal_status(RDMA_SC_INVALID_STATE, status.message);
    status = journal_row_set_existence_locked(
      candidate_key, row_set_present
    );
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ batch allocation row-set check returned null status"
      );
    if (!status.ok())
      return journal_status(RDMA_SC_INVALID_STATE, status.message);
    if (row_set_present)
      return journal_status(
        RDMA_SC_RESOURCE_BUSY, "CMQ batch key is already allocated"
      );
    batch_id_counter = candidate_id;
    batch_key = candidate_key;
    batch_id = candidate_id;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：在锁内分配下一个 engine-lifetime attempt ID，成功值始终非零且不复用。
  // 输入/输出及副作用：attempt_id 入口清零；成功推进 attempt_id_counter 并发布值。
  // 失败/边界：counter 已为 64 位最大值时返回 RESOURCE_EXHAUSTED，状态不变。
  protected function rdma_status allocate_attempt_id_locked(
    output longint unsigned attempt_id
  );
    attempt_id = 0;
    if (attempt_id_counter == 64'hffff_ffff_ffff_ffff)
      return journal_status(
        RDMA_SC_RESOURCE_EXHAUSTED, "CMQ attempt IDs are exhausted"
      );
    attempt_id_counter++;
    attempt_id = attempt_id_counter;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：在锁内分配下一个 engine-lifetime reset-proof ID，保持非零单调身份。
  // 输入/输出及副作用：proof_id 入口清零；成功推进 reset_proof_id_counter。
  // 失败/边界：counter 最大值时返回 RESOURCE_EXHAUSTED，不回绕或发布 partial 值。
  protected function rdma_status allocate_reset_proof_id_locked(
    output longint unsigned proof_id
  );
    proof_id = 0;
    if (reset_proof_id_counter == 64'hffff_ffff_ffff_ffff)
      return journal_status(
        RDMA_SC_RESOURCE_EXHAUSTED, "CMQ reset proof IDs are exhausted"
      );
    reset_proof_id_counter++;
    proof_id = reset_proof_id_counter;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：把完整 source record、ticket index、预分配值和 exact profile 作为一个原子行组安装。
  // 输入/输出及副作用：record/preallocated 为非拥有输入；成功后四张表拥有 detached
  //   record/preallocation，profile 表仅保存安装时 service 的非拥有句柄。
  // 失败/边界：未配置 profile、candidate digest/graph/cardinality、batch/ticket collision
  //   或 snapshot seam 失败时零行提交；duplicate key/ticket 返回 RESOURCE_BUSY。
  protected function rdma_status install_submission_journal_locked(
    input rdma_cmq_batch_submission_record record,
    input rdma_cmq_preallocated_publish_batch preallocated
  );
    rdma_cmq_batch_submission_record record_snapshot;
    rdma_cmq_preallocated_publish_batch preallocated_snapshot;
    bit row_set_present;
    string candidate_ticket_keys[$];
    rdma_status status;

    if (record == null || preallocated == null)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal installation source record or preallocation is null"
      );
    if (profile == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal installation has no active profile service"
      );
    status = journal_row_set_existence_locked(
      record.batch_key, row_set_present
    );
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal installation row-set check returned null status"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    status = journal_ticket_index_targets_locked();
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal installation ticket target check returned null status"
      );
    if (!status.ok())
      return journal_status(RDMA_SC_INVALID_STATE, status.message);
    if (row_set_present)
      return journal_status(
        RDMA_SC_RESOURCE_BUSY, "CMQ journal batch key is already installed"
      );

    status = validate_submission_record_locked(record, profile, 1'b1);
    if (status == null || !status.ok())
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal candidate validation returned null status"
      ) : journal_status(status.code, status.message);
    foreach (record.items[i]) begin
      string ticket_key;

      ticket_key = command_key(record.items[i].ticket);
      if (journal_batch_by_ticket.exists(ticket_key))
        return journal_status(
          RDMA_SC_RESOURCE_BUSY,
          "CMQ journal ticket identity is already installed"
        );
      candidate_ticket_keys.push_back(ticket_key);
    end

    status = snapshot_journal_record_with_profile_locked(
      record, profile, record_snapshot
    );
    if (status == null || !status.ok() || record_snapshot == null)
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal candidate snapshot returned null status"
      ) : journal_status(status.code, status.message);
    status = validate_submission_record_locked(
      record_snapshot, profile, 1'b1
    );
    if (status == null || !status.ok())
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal detached candidate validation returned null status"
      ) : journal_status(status.code, status.message);
    status = snapshot_preallocated_publish_batch_locked(
      preallocated, record, record_snapshot, preallocated_snapshot
    );
    if (status == null || !status.ok() || preallocated_snapshot == null)
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ preallocated publication snapshot returned null status"
      ) : journal_status(status.code, status.message);

    // 所有可能失败的构造、canonicalization 与 collision 检查已经完成；以下
    // 连续赋值在 engine_lock 下形成不可观察到中间态的单次 publication commit。
    submission_journal[record.batch_key] = record_snapshot;
    preallocated_publish_batches[record.batch_key] =
      preallocated_snapshot;
    journal_profile_by_batch[record.batch_key] = profile;
    foreach (candidate_ticket_keys[i])
      journal_batch_by_ticket[candidate_ticket_keys[i]] = record.batch_key;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 设计说明：该公开入口只因独立声明的 observer 需要同步回调而公开；
  //   调用方已持 engine_lock，因此认证先完整收集只读证据，通过后才做
  //   无失败的句柄转移与标量状态迁移，禁止任何构造或外部重入。
  // 功能：认证 exact registered observer 及 journal tuple，包括 slot 中的
  //   batch key/压缩 item 下标；把预分配 slot/token/command/entry 安装到
  //   runtime，并把 batch/items 推进到 PUBLISH_AMBIGUOUS。
  // 输入/输出及副作用：observer 为非拥有输入；成功推进 publish_seq 一次、
  //   安装预建句柄/索引、更新 MMIO_MAYBE_VISIBLE 证据，再删除 capability
  //   与 preallocation 行；不取锁、不等待、不调用 scheduler/service/adapter。
  // 失败/边界：null/未配置、owner/key/handle identity 伪造、tuple 漂移、
  //   缺行、stale lifecycle、cursor/slot/token/registry 冲突或重复调用均只发布
  //   RDMA_CMQ_MMIO_ARM_INVALID 且零状态变化；有效 capability 是无可恢复失败的内部不变量。
  function void arm_submission_for_mmio(
    input rdma_cmq_mmio_arm_observer observer
  );
    rdma_cmq_batch_submission_record record;
    rdma_cmq_preallocated_publish_batch preallocated;
    string capability_key;
    string batch_key;
    bit valid;
    rdma_submission_effect_e armed_cumulative;

    record = null;
    preallocated = null;
    capability_key = "";
    batch_key = "";
    valid = observer != null;
    if (valid) begin
      valid = observer.is_configured() && observer.owner_handle() == this;
      if (valid) begin
        capability_key = observer.get_capability_key();
        batch_key = observer.get_batch_key();
        valid = capability_key.len() != 0 && batch_key.len() != 0 &&
                observer.get_attempt_id() != 0 &&
                observer.get_engine_incarnation() != 0 &&
                arm_observers.exists(capability_key) &&
                arm_observers[capability_key] == observer &&
                submission_journal.exists(batch_key) &&
                preallocated_publish_batches.exists(batch_key) &&
                journal_profile_by_batch.exists(batch_key);
      end
      if (valid) begin
        record = submission_journal[batch_key];
        preallocated = preallocated_publish_batches[batch_key];
        valid = record != null && preallocated != null &&
                journal_profile_by_batch[batch_key] != null;
      end
      if (valid)
        valid = record.batch_key == batch_key &&
                record.attempt_id == observer.get_attempt_id() &&
                record.engine_incarnation ==
                  observer.get_engine_incarnation() &&
                engine_incarnation == observer.get_engine_incarnation() &&
                record.state == RDMA_CMQ_SUBMISSION_PENDING_EFFECT &&
                record.observer_armed == 1'b0 &&
                record.submission_effect inside {
                  RDMA_SUBMIT_EFFECT_UNOBSERVED,
                  RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
                  RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
                  RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED
                } && record.attempt_effect inside {
                  RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
                  RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
                  RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED
                } &&
                record.items.size() != 0 &&
                record.start_sequence == publish_seq &&
                record.end_sequence > record.start_sequence &&
                record.end_sequence - record.start_sequence ==
                  record.items.size() &&
                preallocated.batch_key == batch_key &&
                preallocated.attempt_id == observer.get_attempt_id() &&
                preallocated.final_sequence == record.end_sequence &&
                preallocated.profile_format_valid &&
                preallocated.profile_endian inside {
                  RDMA_ENDIAN_LITTLE, RDMA_ENDIAN_BIG
                } && preallocated.profile_hardware_version != 0 &&
                preallocated.items.size() == record.items.size();
      if (valid)
        valid = rdma_cmq_fold_attempt_effect(
          record.submission_effect,
          RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
          armed_cumulative
        );
      if (valid && profile_image_format_valid)
        valid = profile_image_endian == preallocated.profile_endian &&
                profile_hardware_version ==
                  preallocated.profile_hardware_version;
      if (valid) begin
        foreach (record.items[i]) begin
          rdma_cmq_batch_submission_item_record item;
          rdma_cmq_preallocated_publish_item preallocated_item;

          item = record.items[i];
          preallocated_item = preallocated.items[i];
          if (item == null || preallocated_item == null ||
              preallocated_item.slot_record == null) begin
            valid = 1'b0;
            break;
          end
          if (item.state != RDMA_CMQ_SUBMISSION_PENDING_EFFECT ||
              item.submission_effect != record.submission_effect ||
              item.attempt_effect != record.attempt_effect ||
              item.completion_phase != RDMA_CMQ_COMPLETION_NONE ||
              item.reset_isolation_confirmed || !item.recovery_required ||
              preallocated_item.request_index != item.request_index ||
              preallocated_item.command_key.len() == 0 ||
              preallocated_item.entry_key.len() == 0 ||
              preallocated_item.entry_key != item.entry_key ||
              preallocated_item.command_token != item.command_token ||
              preallocated_item.slot_record.ticket != item.ticket ||
              preallocated_item.slot_record.slot_sequence !=
                item.slot_sequence ||
              preallocated_item.slot_record.sq_index != item.slot_index ||
              preallocated_item.slot_record.sq_wrap != item.slot_wrap ||
              preallocated_item.slot_record.state != CMQ_SLOT_PUBLISHED ||
              preallocated_item.slot_record.expected == null ||
              preallocated_item.slot_record.command_token !=
                item.command_token ||
              preallocated_item.slot_record.batch_key != batch_key ||
              preallocated_item.slot_record.journal_item_index != i ||
              item.slot_index >= CMQ_DEPTH ||
              slots[item.slot_index] != null ||
              token_in_use[item.command_token] ||
              command_registry.exists(preallocated_item.command_key) ||
              entry_registry.exists(preallocated_item.entry_key)) begin
            valid = 1'b0;
            break;
          end
          for (int unsigned prior = 0; prior < i; prior++) begin
            if (preallocated.items[prior] == null ||
                preallocated.items[prior].slot_record == null ||
                preallocated.items[prior].slot_record.sq_index ==
                  preallocated_item.slot_record.sq_index ||
                preallocated.items[prior].command_token ==
                  preallocated_item.command_token ||
                preallocated.items[prior].command_key ==
                  preallocated_item.command_key ||
                preallocated.items[prior].entry_key ==
                  preallocated_item.entry_key) begin
              valid = 1'b0;
              break;
            end
          end
          if (!valid)
            break;
        end
      end
    end

    if (!valid) begin
      `uvm_error("RDMA_CMQ_MMIO_ARM_INVALID",
                 "CMQ MMIO arm capability is invalid")
      return;
    end

    // 全部认证、cardinality 与冲突检查已完成；以下路径只转移
    // 预建句柄、写标量和删关联行，不包含 new/factory/format/wait/lock/
    // scheduler/service/adapter 调用，不存在可观察的 partial failure。
    foreach (record.items[i]) begin
      rdma_cmq_batch_submission_item_record item;
      rdma_cmq_preallocated_publish_item preallocated_item;
      int unsigned slot_index;
      int unsigned token_index;

      item = record.items[i];
      preallocated_item = preallocated.items[i];
      slot_index = preallocated_item.slot_record.sq_index;
      token_index = preallocated_item.command_token;
      slots[slot_index] = preallocated_item.slot_record;
      token_in_use[token_index] = 1'b1;
      command_registry[preallocated_item.command_key] =
        preallocated_item.slot_record;
      entry_registry[preallocated_item.entry_key] =
        preallocated_item.slot_record;
      item.state = RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS;
      item.submission_effect = armed_cumulative;
      item.attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
      item.completion_phase = RDMA_CMQ_COMPLETION_PENDING;
      item.recovery_required = 1'b1;
    end
    publish_seq = preallocated.final_sequence;
    profile_image_format_valid = preallocated.profile_format_valid;
    profile_image_endian = preallocated.profile_endian;
    profile_hardware_version = preallocated.profile_hardware_version;
    record.state = RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS;
    record.submission_effect = armed_cumulative;
    record.attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
    record.observer_armed = 1'b1;
    if (fenced_batch_key == batch_key) begin
      fenced_batch_key = "";
      submission_fence_reason = "";
    end
    arm_observers.delete(capability_key);
    preallocated_publish_batches.delete(batch_key);
  endfunction

  // 功能：在完整结构预检后同步删除一个 batch 的 record/index/preallocation/profile 行。
  // 输入/输出及副作用：batch_key 为输入；成功删除该批次四表和全部 ticket 索引。
  // 失败/边界：未知 key 返回 INVALID_ARGUMENT；任一 retained invariant 损坏返回
  //   INVALID_STATE 且不删任何行，重复删除不伪装成幂等成功。
  protected function rdma_status remove_submission_journal_locked(
    input string batch_key
  );
    rdma_cmq_batch_submission_record record;
    string ticket_keys[$];
    rdma_status status;

    if (batch_key.len() == 0)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT, "CMQ journal batch key is not installed"
      );
    status = submission_journal_invariant_locked(batch_key);
    if (status == null || !status.ok())
      return (status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal removal invariant returned null status"
      ) : journal_status(status.code, status.message);
    record = submission_journal[batch_key];
    foreach (record.items[i])
      ticket_keys.push_back(command_key(record.items[i].ticket));

    foreach (ticket_keys[i])
      journal_batch_by_ticket.delete(ticket_keys[i]);
    submission_journal.delete(batch_key);
    preallocated_publish_batches.delete(batch_key);
    journal_profile_by_batch.delete(batch_key);
    if (fenced_batch_key == batch_key) begin
      fenced_batch_key = "";
      submission_fence_reason = "";
    end
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：锁内按 batch key 重验 retained profile/digest 并发布一份完整 detached record。
  // 输入/输出及副作用：batch_key 为输入，record 入口清空；只读四表与 exact profile。
  // 失败/边界：未知 key 为 INVALID_ARGUMENT；结构、profile name/seam、stored graph 或
  //   carried digest 损坏统一转 INVALID_STATE/null，不回退当前 profile。
  protected function rdma_status query_submission_journal_locked(
    input string batch_key,
    output rdma_cmq_batch_submission_record record
  );
    rdma_cmq_batch_submission_record candidate;
    rdma_cmq_hw_profile retained_profile;
    rdma_status status;

    record = null;
    if (batch_key.len() == 0)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT, "CMQ journal batch key is not installed"
      );
    status = submission_journal_invariant_locked(batch_key);
    if (status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal invariant returned null status"
      );
    if (!status.ok())
      return journal_status(status.code, status.message);
    retained_profile = journal_profile_by_batch[batch_key];
    if (retained_profile == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal retained profile service is missing"
      );
    status = validate_submission_record_locked(
      submission_journal[batch_key], retained_profile, 1'b0
    );
    if (status == null || !status.ok())
      return journal_status(
        RDMA_SC_INVALID_STATE,
        (status == null) ?
          "CMQ retained journal validation returned null status" :
          status.message
      );
    status = snapshot_journal_record_with_profile_locked(
      submission_journal[batch_key], retained_profile, candidate
    );
    if (status == null || !status.ok() || candidate == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        (status == null) ?
          "CMQ retained journal snapshot returned null status" :
          status.message
      );
    status = validate_submission_record_locked(
      candidate, retained_profile, 1'b0
    );
    if (status == null || !status.ok())
      return journal_status(
        RDMA_SC_INVALID_STATE,
        (status == null) ?
          "CMQ detached journal validation returned null status" :
          status.message
      );
    record = candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：按 canonical batch key 查询 engine-owned journal 并返回 detached snapshot。
  // 输入/输出及副作用：batch_key 为输入，record/status 为输出；入口清空 record，
  //   获取且仅获取现有 engine_lock，成功后调用方独占返回图。
  // 失败/边界：未知 key 为 INVALID_ARGUMENT；retained metadata/profile/digest 损坏为
  //   INVALID_STATE；所有路径释放锁且不发布 partial graph。
  task query_submission_journal(
    input string batch_key,
    output rdma_cmq_batch_submission_record record,
    output rdma_status status
  );
    record = null;
    status = journal_status(
      RDMA_SC_INVALID_STATE, "CMQ journal query did not complete"
    );
    engine_lock.get(1);
    status = query_submission_journal_locked(batch_key, record);
    if (status == null) begin
      record = null;
      status = journal_status(
        RDMA_SC_INVALID_STATE, "CMQ journal query returned null status"
      );
    end
    engine_lock.put(1);
  endtask

  // 功能：以 caller ticket 稳定 key 定位 batch，先验证 retained graph 再比较全值。
  // 输入/输出及副作用：ticket 为 detached 只读输入，record/status 为输出；持锁
  //   审计全局 index，并只在 validated local candidate 唯一匹配后发布 record。
  // 失败/边界：坏/未知 caller 或 valid retained 上的全值不匹配为 INVALID_ARGUMENT；
  //   orphan/index 歧义与任意 retained corruption 为 INVALID_STATE/null output。
  task query_submission_journal_by_ticket(
    input rdma_cmq_ticket ticket,
    output rdma_cmq_batch_submission_record record,
    output rdma_status status
  );
    rdma_cmq_batch_submission_record candidate;
    rdma_cmq_ticket ticket_snapshot;
    string ticket_key;
    string batch_key;
    int unsigned match_count;

    record = null;
    status = journal_status(
      RDMA_SC_INVALID_STATE, "CMQ journal ticket query did not complete"
    );
    engine_lock.get(1);
    if (!rdma_cmq_ticket_shape_valid(ticket)) begin
      status = journal_status(
        RDMA_SC_INVALID_ARGUMENT, "CMQ journal query ticket is invalid"
      );
      engine_lock.put(1);
      return;
    end
    status = checked_completion_ticket_snapshot(ticket, ticket_snapshot);
    if (status == null || !status.ok() || ticket_snapshot == null) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        (status == null) ?
          "CMQ journal query ticket snapshot returned null status" :
          {"CMQ journal query ticket snapshot failed: ", status.message}
      );
      engine_lock.put(1);
      return;
    end
    ticket_key = command_key(ticket_snapshot);
    status = journal_ticket_index_targets_locked();
    if (status == null) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket target check returned null status"
      );
      engine_lock.put(1);
      return;
    end
    if (!status.ok()) begin
      status = journal_status(RDMA_SC_INVALID_STATE, status.message);
      engine_lock.put(1);
      return;
    end
    if (!journal_batch_by_ticket.exists(ticket_key)) begin
      status = journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal query ticket is not installed"
      );
      engine_lock.put(1);
      return;
    end
    batch_key = journal_batch_by_ticket[ticket_key];
    status = query_submission_journal_locked(batch_key, candidate);
    if (status == null) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket query returned null status"
      );
      engine_lock.put(1);
      return;
    end
    if (!status.ok()) begin
      record = null;
      engine_lock.put(1);
      return;
    end
    match_count = 0;
    foreach (candidate.items[i]) begin
      if (same_ticket_value(ticket_snapshot, candidate.items[i].ticket))
        match_count++;
    end
    if (match_count == 0) begin
      status = journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ journal ticket key matched but full ticket value differs"
      );
      engine_lock.put(1);
      return;
    end
    if (match_count != 1) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal ticket resolves to more than one retained item"
      );
      engine_lock.put(1);
      return;
    end
    record = candidate;
    status = journal_status(RDMA_SC_OK);
    engine_lock.put(1);
  endtask

  // 功能：查询 submission fence 的 exact key/reason 值，不暴露 journal 对象句柄。
  // 输入/输出及副作用：active/batch_key/reason/status 为输出；持现有 engine_lock
  //   读取两个字符串，空/空表示 inactive，非空/非空表示 active。
  // 失败/边界：仅一项非空说明内部 fence partial，返回 INVALID_STATE 且清空输出；
  //   重复查询不改变 fence、journal 或 lifecycle。
  task query_submission_fence(
    output bit active,
    output string batch_key,
    output string reason,
    output rdma_status status
  );
    active = 1'b0;
    batch_key = "";
    reason = "";
    status = journal_status(
      RDMA_SC_INVALID_STATE, "CMQ submission fence query did not complete"
    );
    engine_lock.get(1);
    if ((fenced_batch_key.len() == 0) !=
        (submission_fence_reason.len() == 0)) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ submission fence key/reason state is partial"
      );
      engine_lock.put(1);
      return;
    end
    if (fenced_batch_key.len() != 0) begin
      active = 1'b1;
      batch_key = fenced_batch_key;
      reason = submission_fence_reason;
    end
    status = journal_status(RDMA_SC_OK);
    engine_lock.put(1);
  endtask

  // 功能：清空一次 active runtime 的配置、facade、格式 authority 和短生命周期
  //   ring 账本，使后续 prepare 可创建新 incarnation。
  // 输入/输出及副作用：无输入和返回值；清空协作者引用、ring counter、FIFO、
  //   registry 与 slot/token；保留 engine/journal 单调 ID、四表、profile 行和 fence。
  // 失败/边界：函数不调用 adapter release，调用方必须先处理 backing 所有权；
  //   重复清理幂等，且不得静默删除仍需诊断/恢复的 retained journal record。
  protected function void clear_configuration();
    prepared_binding = null;
    dma_context = null;
    cmq_snapshot = null;
    backing_mapping = null;
    host_mem = null;
    scheduler = null;
    transport = null;
    profile = null;
    publish_seq = 0;
    retire_seq = 0;
    cq_consume_seq = 0;
    profile_image_format_valid = 1'b0;
    profile_image_endian = RDMA_ENDIAN_LITTLE;
    profile_hardware_version = 0;
    command_registry.delete();
    entry_registry.delete();
    terminal_fifo.delete();
    diagnostic_fifo.delete();
    late_final_fifo.delete();
    last_poison = null;
    backing_release_opaque = 1'b0;
    foreach (slots[i]) begin
      slots[i] = null;
      token_in_use[i] = 1'b0;
    end
  endfunction

  // 功能：执行 retain_release_authority 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：retained_mapping（输入）、retained_host_mem（输入）；retain_release_authority 读取 retained_mapping、retained_host_mem 并使用字段 retained_last_poison、last_poison、backing_mapping、host_mem、engine_state；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：retain_release_authority 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  protected function void retain_release_authority(
    rdma_dma_mapping retained_mapping,
    rdma_host_mem_api retained_host_mem,
    bit use_opaque = 1'b0
  );
    rdma_cmq_diagnostic retained_last_poison;
    rdma_cmq_completion retained_terminal_fifo[$];

    retained_last_poison = last_poison;
    // reset() 可能已经把已发布事务转换为 RESET_CANCELLED，并暂存到
    // terminal_fifo；此时 backing release 失败，重试仍必须能够交付这些
    // completion。先保留 FIFO，再清掉其余运行账本，避免清理失败丢失交付权。
    foreach (terminal_fifo[i])
      retained_terminal_fifo.push_back(terminal_fifo[i]);
    clear_configuration();
    last_poison = retained_last_poison;
    foreach (retained_terminal_fifo[i])
      terminal_fifo.push_back(retained_terminal_fifo[i]);
    if (retained_mapping != null) begin
      backing_mapping = retained_mapping;
      host_mem = retained_host_mem;
      backing_release_opaque = use_opaque;
    end
    engine_state = RDMA_CMQ_ENGINE_POISONED;
  endfunction

  // 功能：在 rdma_cmq_engine 中，rollback_candidate 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：candidate_host_mem（输入）、candidate_mapping（输入）、original_failure（输入）、mapping_validated（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：mapping_validated 为 0 时只能依赖 opaque allocation identity；验证过 public authority 后才使用严格 release。释放失败会保留相同模式的恢复 authority。
  protected function rdma_status rollback_candidate(
    rdma_host_mem_api candidate_host_mem,
    rdma_dma_mapping candidate_mapping,
    rdma_status original_failure,
    bit mapping_validated = 1'b0
  );
    rdma_status release_status;
    rdma_status cleanup_failure;
    string original_message;

    if (original_failure == null)
      original_failure = invalid_state("CMQ prepare failed with null status");
    if (candidate_mapping == null)
      return original_failure;
    if (mapping_validated)
      release_status = candidate_host_mem.\release (candidate_mapping);
    else
      release_status = candidate_host_mem.release_opaque(candidate_mapping);
    if (release_status != null && release_status.ok()) begin
      clear_configuration();
      engine_state = RDMA_CMQ_ENGINE_UNCONFIGURED;
      return original_failure;
    end
    original_message = original_failure.message;
    retain_release_authority(candidate_mapping, candidate_host_mem,
                             !mapping_validated);
    if (release_status == null)
      cleanup_failure = invalid_state(
        {"CMQ prepare rollback release returned null; original failure: ",
         original_message}
      );
    else
      cleanup_failure = rdma_status::make(
        release_status.code,
        {"CMQ prepare rollback release failed: ", release_status.message,
         "; original failure: ", original_message}
      );
    return cleanup_failure;
  endfunction

  // 功能：验证 PREPARED binding/CMQ/profile，配置本 incarnation 的新
  //   transport，申请并清零 backing，最后原子提交 runtime 与协作者引用。
  // 输入/输出及副作用：binding/cmq/pasid/host_mem/scheduler/profile 为非拥有
  //   输入；成功驱动一次 allocate/zero-write，原子发布 runtime_desc 并把
  //   engine_incarnation 恰好推进一次；失败不推进 incarnation。
  // 失败/边界：重复 prepare、incarnation 溢出、空依赖、authority/profile/facade
  //   配置失败在外部 I/O 前拒绝；allocate 后失败走 rollback，候选 transport 不安装。
  task prepare(
    rdma_function_binding binding,
    rdma_cmq cmq,
    bit pasid_valid,
    bit [19:0] pasid,
    rdma_host_mem_api host_mem,
    rdma_doorbell_scheduler scheduler,
    rdma_cmq_hw_profile profile,
    output rdma_cmq_runtime_desc runtime_desc,
    output rdma_status status
  );
    rdma_function_binding binding_candidate;
    rdma_cmq cmq_candidate;
    rdma_dma_request_context context_candidate;
    rdma_dma_mapping mapping_candidate;
    rdma_cmq_runtime_desc runtime_candidate;
    rdma_cmq_runtime_desc published_runtime;
    rdma_cmq_transport transport_candidate;
    byte zeros[];

    runtime_desc = null;
    status = invalid_state("CMQ prepare did not complete");
    engine_lock.get(1);
    if (engine_state != RDMA_CMQ_ENGINE_UNCONFIGURED) begin
      status = invalid_state("CMQ engine is already configured");
      engine_lock.put(1);
      return;
    end
    if (engine_incarnation == 64'hffff_ffff_ffff_ffff) begin
      status = journal_status(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "CMQ engine incarnation IDs are exhausted"
      );
      engine_lock.put(1);
      return;
    end

    status = clone_binding_snapshot(binding, binding_candidate);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    status = prepared_binding_status(binding_candidate);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    status = clone_cmq_snapshot(cmq, cmq_candidate);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    status = cmq_resource_status(cmq_candidate, binding_candidate);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    if (host_mem == null) begin
      status = invalid_argument("CMQ host memory adapter is null");
      engine_lock.put(1);
      return;
    end
    if (scheduler == null) begin
      status = invalid_argument("CMQ doorbell scheduler is null");
      engine_lock.put(1);
      return;
    end
    if (profile == null) begin
      status = invalid_argument("CMQ hardware profile is null");
      engine_lock.put(1);
      return;
    end
    status = profile.validate_profile();
    if (status == null)
      status = invalid_state("CMQ hardware profile returned null status");
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    status = make_request_context(binding_candidate, cmq_candidate,
                                  pasid_valid, pasid, context_candidate);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end

    // facade 在任何 Host-memory I/O 前完成一次性配置；只有 prepare 的最终
    //   commit 才把 candidate 装入 engine，所有早退和 rollback 都无法留下旧引用。
    transport_candidate = rdma_cmq_transport::type_id::create(
      "cmq_transport_candidate"
    );
    if (transport_candidate == null) begin
      status = invalid_state("CMQ transport construction failed");
      engine_lock.put(1);
      return;
    end
    status = transport_candidate.configure(scheduler);
    if (status == null)
      status = invalid_state("CMQ transport configure returned null status");
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end

    mapping_candidate = null;
    status = host_mem.allocate(context_candidate, BACKING_BYTES,
                               BACKING_BYTES, RDMA_DMA_BIDIRECTIONAL,
                               mapping_candidate);
    if (status == null)
      status = invalid_state("CMQ host allocation returned null status");
    if (!status.ok()) begin
      if (mapping_candidate != null)
        status = rollback_candidate(host_mem, mapping_candidate, status);
      engine_lock.put(1);
      return;
    end
    status = mapping_authority_status(mapping_candidate,
                                      context_candidate);
    if (!status.ok()) begin
      status = rollback_candidate(host_mem, mapping_candidate, status);
      engine_lock.put(1);
      return;
    end

    zeros = new[BACKING_BYTES];
    foreach (zeros[i])
      zeros[i] = 0;
    status = host_mem.write(mapping_candidate, 0, zeros);
    if (status == null)
      status = invalid_state("CMQ backing zero-write returned null status");
    if (!status.ok()) begin
      status = rollback_candidate(host_mem, mapping_candidate, status,
                                  1'b1);
      engine_lock.put(1);
      return;
    end
    status = build_runtime_desc(context_candidate, cmq_candidate,
                                mapping_candidate, runtime_candidate);
    if (status == null)
      status = invalid_state("CMQ runtime construction returned null status");
    if (!status.ok()) begin
      status = rollback_candidate(host_mem, mapping_candidate, status,
                                  1'b1);
      engine_lock.put(1);
      return;
    end
    status = publish_runtime_snapshot(runtime_candidate,
                                      published_runtime);
    if (status == null)
      status = invalid_state("CMQ runtime publication returned null status");
    if (!status.ok() || published_runtime == null) begin
      if (status.ok())
        status = invalid_state("CMQ runtime publication returned null");
      status = rollback_candidate(host_mem, mapping_candidate, status,
                                  1'b1);
      engine_lock.put(1);
      return;
    end

    cmq_candidate.queue_iova = runtime_candidate.sq_iova;
    cmq_candidate.completion_iova = runtime_candidate.cq_iova;
    prepared_binding = binding_candidate;
    dma_context = context_candidate;
    cmq_snapshot = cmq_candidate;
    backing_mapping = mapping_candidate;
    this.host_mem = host_mem;
    this.scheduler = scheduler;
    this.transport = transport_candidate;
    this.profile = profile;
    publish_seq = 0;
    retire_seq = 0;
    cq_consume_seq = 0;
    profile_image_format_valid = 1'b0;
    profile_image_endian = RDMA_ENDIAN_LITTLE;
    profile_hardware_version = 0;
    command_registry.delete();
    entry_registry.delete();
    terminal_fifo.delete();
    diagnostic_fifo.delete();
    late_final_fifo.delete();
    foreach (slots[i]) begin
      slots[i] = null;
      token_in_use[i] = 1'b0;
    end
    engine_incarnation++;
    engine_state = RDMA_CMQ_ENGINE_PREPARED;
    runtime_desc = published_runtime;
    status = rdma_status::success();
    engine_lock.put(1);
  endtask

  // 功能：在新 incarnation 已成功 ACTIVE 后，把同一 immutable Function 且
  //       reset epoch 严格递增的 retained AWAITING_REBIND proof 绑定到该
  //       replacement identity，并提升为 READY。
  // 输入/输出及副作用：replacement_identity 为已校验的 ACTIVE detached
  //       identity；只修改匹配 journal row 的 proof state/replacement 字段，
  //       不触碰 backing、fence、attempt 或 scheduler。
  // 失败/边界：不同 Function、相同/回退 epoch、PREPARED-only 或损坏 tuple/
  //       digest 的 proof 均保持 AWAITING_REBIND；promotion 不创建第二份
  //       proof authority，也不因单行不匹配阻断 ACTIVE 建立。
  protected function void promote_reset_proofs_ready_locked(
    input rdma_function_identity replacement_identity
  );
    rdma_function_identity replacement_snapshot;
    rdma_status status;

    if (replacement_identity == null ||
        !rdma_cmq_identity_shape_valid(replacement_identity))
      return;
    if (!rdma_cmq_try_snapshot_identity_direct(
          replacement_identity, replacement_snapshot
        ) || replacement_snapshot == null)
      return;

    foreach (submission_journal[batch_key]) begin
      rdma_cmq_batch_submission_record row;
      rdma_cmq_reset_isolation_proof proof;
      rdma_cmq_journal_digest_t computed_digest;

      row = submission_journal[batch_key];
      if (row == null || row.reset_isolation_proof == null)
        continue;
      proof = row.reset_isolation_proof;
      if (proof.state != RDMA_CMQ_RESET_PROOF_AWAITING_REBIND ||
          !proof.backing_release_confirmed ||
          proof.engine_instance_id != engine_instance_id ||
          proof.engine_incarnation >= engine_incarnation ||
          proof.isolated_identity == null ||
          !replacement_snapshot.same_function(proof.isolated_identity) ||
          replacement_snapshot.reset_epoch <= proof.isolated_identity.reset_epoch)
        continue;
      status = rdma_cmq_compute_reset_proof_digest(
        proof.proof_key, proof.proof_id, proof.batch_key, proof.batch_id,
        proof.attempt_id, proof.engine_instance_id,
        proof.engine_incarnation, proof.isolated_identity,
        proof.batch_digest, proof.isolated_request_indices,
        proof.isolated_image_digests, proof.isolated_authority_digests,
        proof.isolated_recovery_owners, computed_digest
      );
      if (status == null || !status.ok() || computed_digest !== proof.proof_digest)
        continue;
      proof.replacement_identity = replacement_snapshot;
      proof.state = RDMA_CMQ_RESET_PROOF_READY;
    end
  endfunction

  // 功能：在 rdma_cmq_engine 中，activate 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：active_binding（输入）、status（输出）；activate 先依据 engine_state != RDMA_CMQ_ENGINE_PREPARED；!status.ok(；prepared_binding == null 校验 active_binding、status；成功时更新本对象配置/状态并保存非拥有引用，返回 无直接返回值。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  task activate(
    rdma_function_binding active_binding,
    output rdma_status status
  );
    rdma_function_binding binding_candidate;

    status = invalid_state("CMQ activate did not complete");
    engine_lock.get(1);
    if (engine_state != RDMA_CMQ_ENGINE_PREPARED) begin
      status = invalid_state("CMQ engine is not PREPARED");
      engine_lock.put(1);
      return;
    end
    status = clone_binding_snapshot(active_binding, binding_candidate);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    status = active_binding_status(binding_candidate);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    if (prepared_binding == null) begin
      status = invalid_state("CMQ prepared binding authority is missing");
      engine_lock.put(1);
      return;
    end
    if (binding_candidate.function_uid != prepared_binding.function_uid ||
        binding_candidate.global_function_id !=
          prepared_binding.global_function_id) begin
      status = invalid_argument(
        "CMQ ACTIVE binding Function identity does not match PREPARED"
      );
      engine_lock.put(1);
      return;
    end
    if (binding_candidate.generation != prepared_binding.generation) begin
      status = rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "CMQ ACTIVE binding generation does not match PREPARED"
      );
      engine_lock.put(1);
      return;
    end
    if (!same_bdf(binding_candidate.pcie.bdf,
                  prepared_binding.pcie.bdf)) begin
      status = rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ ACTIVE binding BDF does not match PREPARED"
      );
      engine_lock.put(1);
      return;
    end
    if (binding_candidate.queue_dma.pasid_valid !=
          prepared_binding.queue_dma.pasid_valid ||
        binding_candidate.queue_dma.pasid !=
          prepared_binding.queue_dma.pasid) begin
      status = rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ ACTIVE binding PASID does not match PREPARED"
      );
      engine_lock.put(1);
      return;
    end
    if (binding_candidate.queue_dma.dma_domain_valid !=
          prepared_binding.queue_dma.dma_domain_valid ||
        binding_candidate.queue_dma.dma_domain_id !=
          prepared_binding.queue_dma.dma_domain_id) begin
      status = rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "CMQ ACTIVE binding DMA domain does not match PREPARED"
      );
      engine_lock.put(1);
      return;
    end
    status = mapping_authority_status(backing_mapping, dma_context);
    if (!status.ok()) begin
      engine_lock.put(1);
      return;
    end
    prepared_binding = binding_candidate;
    engine_state = RDMA_CMQ_ENGINE_ACTIVE;
    promote_reset_proofs_ready_locked(
      prepared_binding.function_identity_snapshot()
    );
    status = rdma_status::success();
    engine_lock.put(1);
  endtask

  // 功能：直接复制 submit 路径要返回或写入 journal 的完整 status 标量，
  //   避免 transport 已发生副作用后再依赖 UVM factory/clone。
  // 输入/输出及副作用：source/name 为只读输入；返回调用方拥有的新 status，
  //   不修改 source，也不读取共享 last_* 证据。
  // 失败/边界：source 为 null、runtime subtype 或枚举 shape 非法时返回独立
  //   INVALID_STATE；函数始终返回非空对象。
  protected function rdma_status copy_submit_status_direct(
    input rdma_status source,
    input string name
  );
    rdma_status snapshot;

    if (!rdma_cmq_status_shape_valid(source))
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "CMQ observed submit status is null or malformed"
      );

    snapshot = new(name);
    snapshot.category = source.category;
    snapshot.code = source.code;
    snapshot.hardware_code = source.hardware_code;
    snapshot.hardware_code_valid = source.hardware_code_valid;
    snapshot.source_engine = source.source_engine;
    snapshot.function_uid = source.function_uid;
    snapshot.generation = source.generation;
    snapshot.resource_id = source.resource_id;
    snapshot.command_id = source.command_id;
    snapshot.wr_id = source.wr_id;
    snapshot.severity = source.severity;
    snapshot.retryable = source.retryable;
    snapshot.message = source.message;
    return snapshot;
  endfunction

  // 功能：为一个 input-aligned submit item 直接建立本地拒绝默认结果，
  //   operation 与 observation status 从构造时起始终互相独立且非空。
  // 输入/输出及副作用：name 仅用于新对象诊断名；返回调用方拥有的 result。
  // 失败/边界：默认值表示尚未发布的 PRE_SUBMIT_REJECTED，ticket/IDs 为空且
  //   recovery_required=0；后续 admission 必须显式覆盖 operation evidence。
  protected function rdma_cmq_execution_result new_submit_result_direct(
    input string name
  );
    rdma_cmq_execution_result result;

    result = new(name);
    result.status = rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE, "CMQ submit item was not admitted"
    );
    result.observation_status = rdma_cmq_direct_status(RDMA_SC_OK);
    result.submission_effect = RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
    result.attempt_effect = RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
    result.completion_phase = RDMA_CMQ_COMPLETION_NONE;
    result.recovery_required = 1'b0;
    return result;
  endfunction

  // 功能：从 retained journal item 构造完整 detached observed result，
  //   并把 operation outcome 与本次 observation health 分开发布。
  // 输入/输出及副作用：record/item/observation_code/message 为输入；result
  //   入口清空，成功由既有 nonfatal snapshot seam 发布独立 ticket/owner/DMA/status。
  // 失败/边界：record/item/command identity 不完整，或嵌套 snapshot 拒绝时返回
  //   非空错误与 null result；不修改 journal 或 lifecycle evidence。
  protected function rdma_status build_observed_result_locked(
    input rdma_cmq_batch_submission_record record,
    input rdma_cmq_batch_submission_item_record item,
    input rdma_status_code_e observation_code,
    input string observation_message,
    output rdma_cmq_execution_result result
  );
    rdma_cmq_execution_result source;
    rdma_cmq_command_identity command_identity;
    string failure_reason;

    result = null;
    if (record == null || item == null || item.command == null ||
        item.status == null)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ observed result source journal item is incomplete"
      );

    command_identity = new("cmq_observed_command_identity");
    if (!command_identity.capture_from(item.command, failure_reason))
      return journal_status(
        RDMA_SC_INVALID_STATE,
        {"CMQ observed command identity capture failed: ", failure_reason}
      );

    source = new("cmq_observed_result_source");
    source.ticket = item.ticket;
    source.completion = item.completion;
    source.status = item.status;
    source.observation_status = rdma_cmq_direct_status(
      observation_code, observation_message
    );
    source.command_identity = command_identity;
    source.recovery_owner = item.recovery_owner;
    source.dma_context = item.dma_context;
    source.submission_effect = item.submission_effect;
    source.attempt_effect = item.attempt_effect;
    source.completion_phase = item.completion_phase;
    source.batch_key = record.batch_key;
    source.batch_id = record.batch_id;
    source.attempt_id = record.attempt_id;
    source.recovery_required = item.recovery_required;
    return snapshot_execution_result_locked(source, result);
  endfunction

  // 功能：为 recovery aligned result 直接复制 ticket 全部身份、slot、opcode 与
  //   absolute deadline 字段，允许把含 X 的 deadline 原样带回拒绝结果。
  // 输入/输出及副作用：name/source 为只读输入；成功返回拥有独立嵌套 handle/key
  //   的 ticket，不修改 request、journal 或 deadline。
  // 失败/边界：source/required nested 值缺失或 direct snapshot/cast 失败返回 null；
  //   本函数不把非法 deadline 解释为授权，只负责保留 aligned diagnostics。
  protected function rdma_cmq_ticket make_recovery_ticket_locked(
    input string name,
    input rdma_cmq_ticket source
  );
    rdma_cmq_ticket candidate;
    rdma_handle function_snapshot_base;
    rdma_handle cmq_snapshot;
    rdma_cmq_opcode_key opcode_snapshot;

    if (source == null || source.function_h == null ||
        source.cmq_h == null || source.opcode_key == null ||
        !rdma_cmq_try_snapshot_handle_direct(
          source.function_h, 1'b0, function_snapshot_base
        ) || !rdma_cmq_try_snapshot_handle_direct(
          source.cmq_h, 1'b0, cmq_snapshot
        ) || !rdma_cmq_try_snapshot_opcode_key_direct(
          source.opcode_key, opcode_snapshot
        ))
      return null;
    candidate = new(name);
    if (!$cast(candidate.function_h, function_snapshot_base))
      return null;
    candidate.command_id = source.command_id;
    candidate.cmq_h = cmq_snapshot;
    candidate.slot_sequence = source.slot_sequence;
    candidate.sq_index = source.sq_index;
    candidate.sq_wrap = source.sq_wrap;
    candidate.opcode_key = opcode_snapshot;
    candidate.absolute_deadline = source.absolute_deadline;
    return candidate;
  endfunction

  // 功能：在任何 stale/action/authority 返回前为已结构对齐请求构造等长同序
  //   execution results；request ticket 失败时改从 retained ticket 创建 detached fallback。
  // 输入/输出及副作用：request/record 为只读输入，results 入口按 request 大小重建；
  //   只分配本地候选，不修改 retained row、counter、observer 或外部 I/O。
  // 失败/边界：任一 maker/snapshot/capture 失败仍用 direct-new 保留非空 aligned
  //   outer/ticket shell，并返回首个失败 status；绝不把 retained ticket 引用返回 caller。
  protected function rdma_status stage_recovery_results_locked(
    input rdma_cmq_submission_recovery_request request,
    input rdma_cmq_batch_submission_record record,
    output rdma_cmq_execution_result results[]
  );
    rdma_status first_failure;

    results = new[request.items.size()];
    first_failure = null;
    foreach (results[i]) begin
      rdma_cmq_execution_result result;
      rdma_cmq_ticket ticket_snapshot;
      rdma_cmq_recovery_owner owner_snapshot;
      rdma_dma_request_context dma_snapshot;
      rdma_cmq_command_identity command_identity;
      rdma_status nested_status;
      string failure_reason;

      result = make_recovery_result_locked(
        $sformatf("cmq_recovery_result_%0d", i)
      );
      if (result == null) begin
        result = new($sformatf("cmq_recovery_emergency_result_%0d", i));
        if (first_failure == null)
          first_failure = journal_status(
            RDMA_SC_INVALID_STATE,
            "CMQ recovery result candidate construction failed"
          );
      end
      ticket_snapshot = make_recovery_ticket_locked(
        $sformatf("cmq_recovery_ticket_%0d", i), request.items[i].ticket
      );
      if (ticket_snapshot == null) begin
        if (first_failure == null)
          first_failure = journal_status(
            RDMA_SC_INVALID_ARGUMENT,
            "CMQ recovery aligned ticket snapshot failed"
          );
        ticket_snapshot = make_recovery_ticket_locked(
          $sformatf("cmq_recovery_retained_ticket_%0d", i),
          record.items[i].ticket
        );
      end
      if (ticket_snapshot == null) begin
        ticket_snapshot = new($sformatf(
          "cmq_recovery_emergency_ticket_%0d", i
        ));
        ticket_snapshot.command_id = request.items[i].ticket.command_id;
        ticket_snapshot.slot_sequence =
          request.items[i].ticket.slot_sequence;
        ticket_snapshot.sq_index = request.items[i].ticket.sq_index;
        ticket_snapshot.sq_wrap = request.items[i].ticket.sq_wrap;
        ticket_snapshot.absolute_deadline =
          request.items[i].ticket.absolute_deadline;
      end
      owner_snapshot = make_recovery_owner_locked(
        $sformatf("cmq_recovery_owner_%0d", i),
        request.items[i].recovery_owner
      );
      if (owner_snapshot == null && first_failure == null)
        first_failure = journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery owner candidate construction failed"
        );
      dma_snapshot = null;
      nested_status = snapshot_journal_dma_context_locked(
        request.items[i].dma_context, dma_snapshot
      );
      if ((nested_status == null || !nested_status.ok() ||
           dma_snapshot == null) && first_failure == null)
        first_failure = (nested_status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery DMA snapshot returned null status"
        ) : journal_status(nested_status.code, nested_status.message);
      command_identity = new($sformatf(
        "cmq_recovery_command_identity_%0d", i
      ));
      if (!command_identity.capture_from(
            request.items[i].command, failure_reason
          )) begin
        command_identity = null;
        if (first_failure == null)
          first_failure = journal_status(
            RDMA_SC_INVALID_ARGUMENT,
            {"CMQ recovery command identity capture failed: ",
             failure_reason}
          );
      end

      result.ticket = ticket_snapshot;
      result.completion = null;
      result.status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE, "CMQ recovery attempt did not commit"
      );
      result.observation_status = rdma_cmq_direct_status(RDMA_SC_OK);
      result.command_identity = command_identity;
      result.recovery_owner = owner_snapshot;
      result.dma_context = dma_snapshot;
      result.submission_effect = record.items[i].submission_effect;
      result.attempt_effect = record.items[i].attempt_effect;
      result.completion_phase = record.items[i].completion_phase;
      result.batch_key = record.batch_key;
      result.batch_id = record.batch_id;
      result.attempt_id = record.attempt_id;
      result.recovery_required = 1'b1;
      results[i] = result;
    end
    return (first_failure == null) ? journal_status(RDMA_SC_OK) :
                                     first_failure;
  endfunction

  // 功能：把一个 located/aligned recovery 拒绝同步投影到每个预建 result，保留
  //   可靠 observation OK、当前 attempt identity 与 retained cumulative evidence。
  // 输入/输出及副作用：results 中 outer 值被就地更新；code/message 为只读输入；
  //   不改变 ticket/owner/DMA、journal、fence、counter 或 capability registry。
  // 失败/边界：null result 被忽略以避免二次异常；调用方只可在 staging 已保证
  //   aligned outer 后使用，INVALID/unknown code 仍由 direct status 保守封装。
  protected function void reject_recovery_results_locked(
    input rdma_cmq_execution_result results[],
    input rdma_status_code_e code,
    input string message
  );
    foreach (results[i]) begin
      if (results[i] != null) begin
        results[i].status = rdma_cmq_direct_status(code, message);
        results[i].observation_status = rdma_cmq_direct_status(RDMA_SC_OK);
        results[i].recovery_required = 1'b1;
      end
    end
  endfunction

  // 功能：逐字段比较 request-carried 与 authoritative retained reset proof，覆盖
  //   digest 未包含的 replacement identity、state 与 backing release confirmation。
  // 输入/输出及副作用：lhs/rhs 为只读输入；只返回完整值 equality，不 mint、
  //   推进或登记 proof，也不访问 retry mapping/fence/observer。
  // 失败/边界：null、tuple cardinality、identity/owner 或任一固定/排除字段漂移
  //   返回 0；matching proof digest 本身不足以返回 1。
  protected function bit same_reset_isolation_proof_value(
    input rdma_cmq_reset_isolation_proof lhs,
    input rdma_cmq_reset_isolation_proof rhs
  );
    if (lhs == null || rhs == null || lhs.isolated_identity == null ||
        rhs.isolated_identity == null ||
        lhs.proof_key != rhs.proof_key || lhs.proof_id != rhs.proof_id ||
        lhs.batch_key != rhs.batch_key || lhs.batch_id != rhs.batch_id ||
        lhs.attempt_id != rhs.attempt_id ||
        lhs.engine_instance_id != rhs.engine_instance_id ||
        lhs.engine_incarnation != rhs.engine_incarnation ||
        !lhs.isolated_identity.same_incarnation(rhs.isolated_identity) ||
        ((lhs.replacement_identity == null) !=
         (rhs.replacement_identity == null)) ||
        lhs.batch_digest !== rhs.batch_digest ||
        lhs.proof_digest !== rhs.proof_digest || lhs.state != rhs.state ||
        lhs.backing_release_confirmed != rhs.backing_release_confirmed ||
        lhs.isolated_request_indices.size() !=
          rhs.isolated_request_indices.size() ||
        lhs.isolated_image_digests.size() !=
          rhs.isolated_image_digests.size() ||
        lhs.isolated_authority_digests.size() !=
          rhs.isolated_authority_digests.size() ||
        lhs.isolated_recovery_owners.size() !=
          rhs.isolated_recovery_owners.size())
      return 1'b0;
    if (lhs.replacement_identity != null &&
        !lhs.replacement_identity.same_incarnation(
          rhs.replacement_identity
        ))
      return 1'b0;
    foreach (lhs.isolated_request_indices[i]) begin
      if (lhs.isolated_request_indices[i] !=
            rhs.isolated_request_indices[i] ||
          lhs.isolated_image_digests[i] !==
            rhs.isolated_image_digests[i] ||
          lhs.isolated_authority_digests[i] !==
            rhs.isolated_authority_digests[i] ||
          !same_journal_owner_value(lhs.isolated_recovery_owners[i],
                                    rhs.isolated_recovery_owners[i]))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：把 authoritative retained READY reset proof 重新绑定到当前 journal
  //   batch identity、engine/Function incarnation 与完整 ordered item authority tuple。
  // 输入/输出及副作用：proof/record 为锁内只读输入；逐项比较 request index、
  //   image/authority digest 和完整 frozen owner 值，只返回 detached status。
  // 失败/边界：null、非 READY、backing 未释放、固定身份/tuple cardinality 或任一
  //   item 值漂移返回 INVALID_ARGUMENT；不 mint proof、不更新 lifecycle 或访问 I/O。
  protected function rdma_status
  validate_reset_isolation_proof_binding_locked(
    input rdma_cmq_reset_isolation_proof proof,
    input rdma_cmq_batch_submission_record record
  );
    int unsigned quarantined_count;
    int unsigned match_count;
    bit matched[int unsigned];
    rdma_cmq_journal_digest_t computed_digest;
    rdma_status status;

    if (proof == null || record == null || record.function_identity == null ||
        proof.state != RDMA_CMQ_RESET_PROOF_READY ||
        !proof.backing_release_confirmed ||
        proof.batch_key != record.batch_key ||
        proof.batch_id != record.batch_id ||
        proof.attempt_id != record.attempt_id ||
        proof.engine_instance_id != record.engine_instance_id ||
        proof.engine_incarnation != record.engine_incarnation ||
        proof.isolated_identity == null ||
        !proof.isolated_identity.same_incarnation(
          record.function_identity
        ) || proof.batch_digest !== record.batch_digest ||
        proof.isolated_request_indices.size() == 0 ||
        proof.isolated_request_indices.size() !=
          proof.isolated_image_digests.size() ||
        proof.isolated_request_indices.size() !=
          proof.isolated_authority_digests.size() ||
        proof.isolated_request_indices.size() !=
          proof.isolated_recovery_owners.size())
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset isolation proof does not bind the retained batch"
      );

    quarantined_count = 0;
    foreach (record.items[i]) begin
      if (record.items[i] == null)
        return journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ reset proof retained item is null"
        );
      if (record.items[i].state == RDMA_CMQ_SUBMISSION_RESET_QUARANTINED)
        quarantined_count++;
    end
    if (proof.isolated_request_indices.size() != quarantined_count)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof tuple does not cover exactly quarantined items"
      );

    status = rdma_cmq_compute_reset_proof_digest(
      proof.proof_key, proof.proof_id, proof.batch_key, proof.batch_id,
      proof.attempt_id, proof.engine_instance_id, proof.engine_incarnation,
      proof.isolated_identity, proof.batch_digest,
      proof.isolated_request_indices, proof.isolated_image_digests,
      proof.isolated_authority_digests, proof.isolated_recovery_owners,
      computed_digest
    );
    if (status == null || !status.ok() || computed_digest !== proof.proof_digest)
      return journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ reset proof digest does not match retained authority"
      );

    if (proof.replacement_identity == null ||
        !proof.replacement_identity.same_function(
          proof.isolated_identity
        ) || proof.replacement_identity.reset_epoch <=
          proof.isolated_identity.reset_epoch)
      return journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ reset proof replacement identity is not a newer same Function"
      );

    foreach (proof.isolated_request_indices[p]) begin
      match_count = 0;
      foreach (record.items[i]) begin
        if (record.items[i].request_index ==
              proof.isolated_request_indices[p]) begin
          match_count++;
          if (matched.exists(i))
            return journal_status(
              RDMA_SC_INVALID_ARGUMENT,
              "CMQ reset proof tuple repeats a journal item"
            );
          matched[i] = 1'b1;
          if (record.items[i].state !=
                RDMA_CMQ_SUBMISSION_RESET_QUARANTINED ||
              record.items[i].completion_phase !=
                RDMA_CMQ_COMPLETION_RESET_CANCELLED ||
              record.items[i].completion == null ||
              proof.isolated_image_digests[p] !==
                record.items[i].image_digest ||
              proof.isolated_authority_digests[p] !==
                record.items[i].authority_digest ||
              !same_journal_owner_value(
                proof.isolated_recovery_owners[p],
                record.items[i].recovery_owner
              ))
            return journal_status(
              RDMA_SC_INVALID_ARGUMENT,
              $sformatf(
                "CMQ reset isolation proof item %0d does not bind journal",
                p
              )
            );
        end
      end
      if (match_count != 1)
        return journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ reset proof request index is absent or ambiguous"
        );
    end
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：提交输入对齐的 observed CMQ batch，在 transport 前安装完整 journal、
  //   ticket index、preallocation、profile 与 authentic MMIO observer 图。
  // 输入/输出及副作用：commands 为调用方输入；results 与 commands 等长同序，
  //   batch_status 只描述 orchestration；成功 admission 可能写 Host-memory/MMIO，
  //   并由 observer 或同步返回更新 engine-owned journal/fence/runtime。
  // 失败/边界：空 batch 在取锁前无条件返回 OK；本地拒绝不分配 ID 或调用 transport；
  //   PRE effect 原子回滚，Host 可见、UNOBSERVED 或已 arm 结果保留恢复 authority；
  //   malformed status/effect 分别降级且不覆盖另一字段中仍有效的操作或副作用证据；
  //   legacy recovery owner 即使 dependency 可重放也不授予 automatic publication retry。
  task submit_batch_observed(
    input rdma_cmq_command_desc commands[],
    output rdma_cmq_execution_result results[],
    output rdma_status batch_status
  );
    rdma_cmq_batch_submission_record record_candidate;
    rdma_cmq_batch_submission_record retained_record;
    rdma_cmq_preallocated_publish_batch preallocated_candidate;
    rdma_cmq_mmio_arm_observer observer;
    rdma_doorbell_dependency dependencies[$];
    rdma_doorbell_desc doorbell_candidate;
    rdma_doorbell_desc doorbell_snapshot_desc;
    rdma_doorbell_submission_result transport_result;
    rdma_function_binding journal_binding;
    rdma_function_identity journal_identity;
    rdma_function_handle active_function;
    rdma_handle journal_cmq_h;
    rdma_handle doorbell_encode_target;
    rdma_hw_image doorbell_image;
    rdma_hw_image doorbell_snapshot;
    int unsigned request_indices[$];
    rdma_cmq_journal_digest_t image_digests[$];
    rdma_cmq_journal_digest_t authority_digests[$];
    bit local_result_finalized[];
    rdma_status status;
    rdma_status transaction_status;
    rdma_status operation_status;
    rdma_status_code_e observation_code;
    rdma_submission_effect_e returned_effect;
    longint unsigned batch_id;
    longint unsigned attempt_id;
    longint unsigned final_sequence;
    longint unsigned used;
    int unsigned final_pi;
    bit final_polarity;
    time minimum_remaining;
    time remaining;
    bit transaction_failed;
    bit staged_profile_format_valid;
    rdma_byte_endian_e staged_profile_endian;
    int unsigned staged_profile_hardware_version;
    bit observer_armed;
    bit retry_safe;
    string batch_key;
    string capability_key;
    string observation_message;

    results = new[commands.size()];
    batch_status = rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE, "CMQ observed batch did not complete"
    );
    if (commands.size() == 0) begin
      batch_status = rdma_cmq_direct_status(RDMA_SC_OK);
      return;
    end

    local_result_finalized = new[commands.size()];
    foreach (results[i]) begin
      results[i] = new_submit_result_direct(
        $sformatf("cmq_observed_result_%0d", i)
      );
      local_result_finalized[i] = 1'b0;
    end

    transaction_failed = 1'b0;
    transaction_status = null;
    staged_profile_format_valid = 1'b0;
    staged_profile_endian = RDMA_ENDIAN_LITTLE;
    staged_profile_hardware_version = 0;
    dependencies.delete();

    engine_lock.get(1);
    if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
      batch_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE, "CMQ submit requires an ACTIVE engine"
      );
      foreach (results[i])
        results[i].status = copy_submit_status_direct(
          batch_status, $sformatf("cmq_inactive_item_%0d", i)
        );
      engine_lock.put(1);
      return;
    end
    if (prepared_binding == null || dma_context == null ||
        cmq_snapshot == null || backing_mapping == null ||
        transport == null || profile == null) begin
      batch_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "CMQ ACTIVE publication authority is missing"
      );
      foreach (results[i])
        results[i].status = copy_submit_status_direct(
          batch_status, $sformatf("cmq_missing_authority_item_%0d", i)
        );
      engine_lock.put(1);
      return;
    end
    if (fenced_batch_key.len() != 0) begin
      foreach (results[i])
        results[i].status = rdma_cmq_direct_status(
          RDMA_SC_RESOURCE_BUSY,
          "CMQ submission is fenced by a retained batch"
        );
      batch_status = rdma_cmq_direct_status(RDMA_SC_OK);
      engine_lock.put(1);
      return;
    end

    active_function = prepared_binding.make_handle();
    if (active_function == null) begin
      batch_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE, "CMQ ACTIVE Function handle is missing"
      );
      foreach (results[i])
        results[i].status = copy_submit_status_direct(
          batch_status, $sformatf("cmq_missing_function_item_%0d", i)
        );
      engine_lock.put(1);
      return;
    end
    status = ring_used(used);
    if (status == null || !status.ok()) begin
      batch_status = copy_submit_status_direct(
        status, "cmq_ring_status"
      );
      foreach (results[i])
        results[i].status = copy_submit_status_direct(
          batch_status, $sformatf("cmq_ring_item_%0d", i)
        );
      engine_lock.put(1);
      return;
    end
    status = prepared_binding.snapshot_complete_nonfatal(journal_binding);
    if (status == null || !status.ok() || journal_binding == null) begin
      transaction_status = (status == null) ? rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "CMQ journal binding snapshot returned null status"
      ) : copy_submit_status_direct(status, "cmq_binding_snapshot_status");
      transaction_failed = 1'b1;
    end
    if (!transaction_failed) begin
      status = journal_binding.snapshot_identity_nonfatal(journal_identity);
      if (status == null || !status.ok() || journal_identity == null) begin
        transaction_status = (status == null) ? rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal Function identity snapshot returned null status"
        ) : copy_submit_status_direct(
          status, "cmq_identity_snapshot_status"
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed &&
        !rdma_cmq_try_snapshot_handle_direct(
          cmq_snapshot.handle, 1'b0, journal_cmq_h
        )) begin
      transaction_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE, "CMQ journal handle snapshot failed"
      );
      transaction_failed = 1'b1;
    end

    record_candidate = new("cmq_submission_record_candidate");
    preallocated_candidate = new("cmq_publish_batch_candidate");
    if (!transaction_failed) begin
      record_candidate.engine_instance_id = engine_instance_id;
      record_candidate.engine_incarnation = engine_incarnation;
      record_candidate.function_identity = journal_identity;
      record_candidate.binding = journal_binding;
      record_candidate.cmq_h = journal_cmq_h;
      record_candidate.start_sequence = publish_seq;
      record_candidate.state = RDMA_CMQ_SUBMISSION_PENDING_EFFECT;
      record_candidate.submission_effect =
        RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
      record_candidate.attempt_effect =
        RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
      record_candidate.observer_armed = 1'b0;
      record_candidate.publication_retry_safe = 1'b0;
      staged_profile_format_valid = profile_image_format_valid;
      staged_profile_endian = profile_image_endian;
      staged_profile_hardware_version = profile_hardware_version;
    end

    if (!transaction_failed) begin
      foreach (commands[i]) begin : stage_observed_command
        rdma_cmq_command_desc command_snapshot;
        rdma_cmq_command_identity command_identity;
        rdma_cmq_slot_context slot_context;
        rdma_cmq_slot_context slot_context_snapshot;
        rdma_hw_image profile_sqe;
        rdma_hw_image sqe_snapshot;
        rdma_cmq_expected_response profile_expected;
        rdma_cmq_expected_response expected_snapshot;
        rdma_cmq_ticket authority_ticket;
        rdma_cmq_slot_record slot_candidate;
        rdma_cmq_slot_record slot_snapshot;
        rdma_doorbell_dependency dependency_candidate;
        rdma_doorbell_dependency dependency_snapshot;
        rdma_dma_mapping dependency_mapping;
        rdma_cmq_batch_submission_item_record item;
        rdma_cmq_preallocated_publish_item publish_item;
        bit [58:0] candidate_token_incarnation;
        time absolute_deadline;
        longint unsigned slot_sequence;
        longint unsigned relative_offset;
        longint unsigned expected_backing_target;
        longint unsigned command_id;
        int unsigned sq_index;
        int unsigned selected_token;
        bit sq_wrap;
        bit token_found;
        bit snapshot_invariant_failed;
        string identity_failure;

        command_snapshot = null;
        command_identity = null;
        slot_context_snapshot = null;
        profile_sqe = null;
        sqe_snapshot = null;
        profile_expected = null;
        expected_snapshot = null;
        authority_ticket = null;
        slot_candidate = null;
        slot_snapshot = null;
        dependency_candidate = null;
        dependency_snapshot = null;
        dependency_mapping = null;
        token_found = 1'b0;
        selected_token = 0;
        snapshot_invariant_failed = 1'b0;

        status = snapshot_command_value(
          commands[i], command_snapshot, snapshot_invariant_failed
        );
        if (status == null)
          status = rdma_cmq_direct_status(
            RDMA_SC_INVALID_STATE,
            "CMQ command snapshot returned null status"
          );
        if (!status.ok()) begin
          if (snapshot_invariant_failed) begin
            transaction_status = status;
            transaction_failed = 1'b1;
            break;
          end
          results[i].status = copy_submit_status_direct(
            status, $sformatf("cmq_local_snapshot_reject_%0d", i)
          );
          local_result_finalized[i] = 1'b1;
          continue;
        end

        command_identity = new($sformatf("cmq_command_identity_%0d", i));
        if (!command_identity.capture_from(
              command_snapshot, identity_failure
            )) begin
          transaction_status = rdma_cmq_direct_status(
            RDMA_SC_INVALID_STATE,
            {"CMQ command identity capture failed: ", identity_failure}
          );
          transaction_failed = 1'b1;
          break;
        end
        results[i].command_identity = command_identity;
        if (command_snapshot.function_h.kind != active_function.kind ||
            command_snapshot.function_h.function_uid !=
              active_function.function_uid ||
            command_snapshot.function_h.object_id !=
              active_function.object_id) begin
          results[i].status = rdma_cmq_direct_status(
            RDMA_SC_INVALID_ARGUMENT,
            "CMQ command Function identity does not match ACTIVE binding"
          );
          local_result_finalized[i] = 1'b1;
          continue;
        end
        if (command_snapshot.function_h.generation !=
            active_function.generation) begin
          results[i].status = rdma_cmq_direct_status(
            RDMA_SC_STALE_GENERATION,
            "CMQ command Function generation does not match ACTIVE binding"
          );
          local_result_finalized[i] = 1'b1;
          continue;
        end
        if (command_snapshot.opcode_key.profile_name !=
            profile.profile_name()) begin
          results[i].status = rdma_cmq_direct_status(
            RDMA_SC_UNSUPPORTED_OPCODE,
            "CMQ command opcode profile does not match ACTIVE profile"
          );
          local_result_finalized[i] = 1'b1;
          continue;
        end
        if ($isunknown(command_snapshot.timeout)) begin
          results[i].status = rdma_cmq_direct_status(
            RDMA_SC_INVALID_ARGUMENT,
            "CMQ command timeout contains an unknown bit"
          );
          local_result_finalized[i] = 1'b1;
          continue;
        end
        absolute_deadline = $time + command_snapshot.timeout;
        if ($isunknown(absolute_deadline) || absolute_deadline == 0 ||
            absolute_deadline < $time) begin
          results[i].status = rdma_cmq_direct_status(
            RDMA_SC_INVALID_ARGUMENT,
            "CMQ command absolute deadline overflows simulation time"
          );
          local_result_finalized[i] = 1'b1;
          continue;
        end
        if ((used + record_candidate.items.size()) == CMQ_DEPTH) begin
          results[i].status = rdma_cmq_direct_status(
            RDMA_SC_QUEUE_FULL, "CMQ submission ring is full"
          );
          local_result_finalized[i] = 1'b1;
          continue;
        end
        if (publish_seq >= 64'hffff_ffff_ffff_ffff -
                           record_candidate.items.size()) begin
          transaction_status = poison_status(
            "CMQ producer sequence addition overflows"
          );
          transaction_failed = 1'b1;
          break;
        end

        for (int unsigned token_index = 0;
             token_index < CMQ_DEPTH; token_index++) begin
          bit staged_token;

          staged_token = 1'b0;
          foreach (record_candidate.items[prior]) begin
            if (record_candidate.items[prior].command_token == token_index)
              staged_token = 1'b1;
          end
          if (!token_found && !token_in_use[token_index] &&
              !staged_token &&
              token_incarnation[token_index] != {59{1'b1}}) begin
            token_found = 1'b1;
            selected_token = token_index;
          end
        end
        if (!token_found) begin
          results[i].status = rdma_cmq_direct_status(
            RDMA_SC_RESOURCE_EXHAUSTED,
            "CMQ command tokens are exhausted"
          );
          local_result_finalized[i] = 1'b1;
          continue;
        end
        candidate_token_incarnation =
          token_incarnation[selected_token] + 1'b1;
        command_id = {candidate_token_incarnation,
                      selected_token[4:0]};
        if (command_id == 0) begin
          results[i].status = rdma_cmq_direct_status(
            RDMA_SC_RESOURCE_EXHAUSTED, "CMQ command ID is exhausted"
          );
          local_result_finalized[i] = 1'b1;
          continue;
        end

        slot_sequence = publish_seq + record_candidate.items.size();
        if (slot_sequence == 64'hffff_ffff_ffff_ffff) begin
          transaction_status = poison_status(
            "CMQ dependency identifier addition overflows"
          );
          transaction_failed = 1'b1;
          break;
        end
        sq_index = slot_sequence % CMQ_DEPTH;
        sq_wrap = (slot_sequence / CMQ_DEPTH) & 1'b1;
        relative_offset = longint'(sq_index) * CMQE_BYTES;
        if (backing_mapping.backing_addr.value >
            64'hffff_ffff_ffff_ffff - relative_offset) begin
          results[i].status = rdma_cmq_direct_status(
            RDMA_SC_DMA_TRANSLATION, "CMQ SQE backing address overflows"
          );
          local_result_finalized[i] = 1'b1;
          continue;
        end
        expected_backing_target = backing_mapping.backing_addr.value +
                                  relative_offset;

        slot_context = rdma_cmq_slot_context::type_id::create(
          $sformatf("cmq_slot_context_%0d", slot_sequence)
        );
        if (slot_context == null) begin
          transaction_status = rdma_cmq_direct_status(
            RDMA_SC_INVALID_STATE, "CMQ slot context construction failed"
          );
          transaction_failed = 1'b1;
          break;
        end
        status = checked_function_snapshot(
          active_function, "CMQ submission slot", RDMA_SC_INVALID_STATE,
          slot_context.function_h
        );
        if (status == null || !status.ok()) begin
          transaction_status = copy_submit_status_direct(
            status, "cmq_slot_function_status"
          );
          transaction_failed = 1'b1;
          break;
        end
        status = checked_handle_snapshot(
          cmq_snapshot.handle, "CMQ submission slot",
          RDMA_SC_INVALID_STATE, slot_context.cmq_h
        );
        if (status == null || !status.ok()) begin
          transaction_status = copy_submit_status_direct(
            status, "cmq_slot_handle_status"
          );
          transaction_failed = 1'b1;
          break;
        end
        slot_context.backing_addr = backing_mapping.backing_addr;
        slot_context.relative_offset = relative_offset;
        slot_context.slot_sequence = slot_sequence;
        slot_context.sq_index = sq_index;
        slot_context.sq_wrap = sq_wrap;
        status = slot_context.validate();
        if (status == null || !status.ok()) begin
          transaction_status = rdma_cmq_direct_status(
            RDMA_SC_INVALID_STATE, "CMQ slot context validation failed"
          );
          transaction_failed = 1'b1;
          break;
        end
        status = checked_slot_context_snapshot(
          slot_context, slot_context_snapshot
        );
        if (status == null || !status.ok()) begin
          transaction_status = copy_submit_status_direct(
            status, "cmq_slot_snapshot_status"
          );
          transaction_failed = 1'b1;
          break;
        end

        status = profile.compose_sqe(
          command_snapshot, slot_context_snapshot,
          profile_sqe, profile_expected
        );
        if (status == null) begin
          transaction_status = rdma_cmq_direct_status(
            RDMA_SC_INVALID_STATE, "CMQ SQE composition returned null status"
          );
          transaction_failed = 1'b1;
          break;
        end
        if (!status.ok()) begin
          results[i].status = copy_submit_status_direct(
            status, $sformatf("cmq_local_compose_reject_%0d", i)
          );
          local_result_finalized[i] = 1'b1;
          continue;
        end
        status = sqe_metadata_status(profile_sqe, expected_backing_target);
        if (status == null || !status.ok()) begin
          transaction_status = copy_submit_status_direct(
            status, "cmq_sqe_metadata_status"
          );
          transaction_failed = 1'b1;
          break;
        end
        status = checked_canonical_image_snapshot(
          profile_sqe, "CMQ SQE", RDMA_SC_INVALID_STATE, sqe_snapshot
        );
        if (status == null || !status.ok()) begin
          transaction_status = copy_submit_status_direct(
            status, "cmq_sqe_snapshot_status"
          );
          transaction_failed = 1'b1;
          break;
        end
        status = sqe_metadata_status(sqe_snapshot, expected_backing_target);
        if (status == null || !status.ok()) begin
          transaction_status = copy_submit_status_direct(
            status, "cmq_sqe_snapshot_metadata_status"
          );
          transaction_failed = 1'b1;
          break;
        end
        if (!staged_profile_format_valid) begin
          staged_profile_format_valid = 1'b1;
          staged_profile_endian = sqe_snapshot.endian;
          staged_profile_hardware_version = sqe_snapshot.hardware_version;
        end
        else if (sqe_snapshot.endian != staged_profile_endian ||
                 sqe_snapshot.hardware_version !=
                   staged_profile_hardware_version) begin
          transaction_status = rdma_cmq_direct_status(
            RDMA_SC_INVALID_STATE,
            "CMQ profile changed its profile-wide SQE/CQE image format"
          );
          transaction_failed = 1'b1;
          break;
        end
        status = checked_expected_snapshot(
          profile_expected, "CMQ profile", RDMA_SC_INVALID_STATE,
          expected_snapshot
        );
        if (status == null || !status.ok()) begin
          transaction_status = copy_submit_status_direct(
            status, "cmq_expected_snapshot_status"
          );
          transaction_failed = 1'b1;
          break;
        end

        status = make_ticket_value(
          $sformatf("cmq_authority_ticket_%0d", command_id), command_id,
          active_function, cmq_snapshot.handle, slot_sequence, sq_index,
          sq_wrap, command_snapshot.opcode_key, absolute_deadline,
          authority_ticket
        );
        if (status == null || !status.ok()) begin
          transaction_status = copy_submit_status_direct(
            status, "cmq_ticket_status"
          );
          transaction_failed = 1'b1;
          break;
        end

        slot_candidate = rdma_cmq_slot_record::type_id::create(
          $sformatf("cmq_slot_record_%0d", slot_sequence)
        );
        if (slot_candidate == null) begin
          transaction_status = rdma_cmq_direct_status(
            RDMA_SC_INVALID_STATE, "CMQ slot record construction failed"
          );
          transaction_failed = 1'b1;
          break;
        end
        slot_candidate.slot_sequence = slot_sequence;
        slot_candidate.sq_index = sq_index;
        slot_candidate.sq_wrap = sq_wrap;
        slot_candidate.state = CMQ_SLOT_PUBLISHED;
        slot_candidate.ticket = authority_ticket;
        slot_candidate.expected = expected_snapshot;
        slot_candidate.command_token = selected_token[4:0];
        status = checked_record_snapshot(slot_candidate, slot_snapshot);
        if (status == null || !status.ok()) begin
          transaction_status = copy_submit_status_direct(
            status, "cmq_slot_record_snapshot_status"
          );
          transaction_failed = 1'b1;
          break;
        end

        dependency_candidate = rdma_doorbell_dependency::type_id::create(
          $sformatf("cmq_dependency_%0d", slot_sequence + 1'b1)
        );
        status = make_mapping_snapshot(
          backing_mapping, $sformatf(
            "cmq_dependency_mapping_%0d", slot_sequence
          ), dependency_mapping
        );
        if (dependency_candidate == null || status == null ||
            !status.ok() || dependency_mapping == null) begin
          transaction_status = rdma_cmq_direct_status(
            RDMA_SC_INVALID_STATE,
            "CMQ scheduler dependency construction failed"
          );
          transaction_failed = 1'b1;
          break;
        end
        dependency_candidate.dependency_id = slot_sequence + 1'b1;
        dependency_candidate.stage = RDMA_DB_DEP_QUEUE_CONTEXT;
        dependency_candidate.mapping = dependency_mapping;
        dependency_candidate.relative_offset = relative_offset;
        dependency_candidate.image = sqe_snapshot;
        dependency_candidate.ready = 1'b1;
        status = checked_dependency_snapshot(
          dependency_candidate, dependency_snapshot
        );
        if (status == null || !status.ok()) begin
          transaction_status = copy_submit_status_direct(
            status, "cmq_dependency_snapshot_status"
          );
          transaction_failed = 1'b1;
          break;
        end

        item = new($sformatf("cmq_submission_item_%0d", i));
        item.request_index = i;
        item.command = command_snapshot;
        item.ticket = authority_ticket;
        item.recovery_owner = null;
        item.dma_context = dma_context;
        item.sqe_image = sqe_snapshot;
        item.dependency_mapping = backing_mapping;
        item.dependency_offset = relative_offset;
        item.dependency_image = sqe_snapshot;
        item.slot_sequence = slot_sequence;
        item.slot_index = sq_index;
        item.slot_wrap = sq_wrap;
        item.command_token = selected_token[4:0];
        item.token_incarnation = engine_incarnation[58:0];
        item.entry_key = entry_key(sq_index, sq_wrap);
        item.state = RDMA_CMQ_SUBMISSION_PENDING_EFFECT;
        item.submission_effect =
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
        item.attempt_effect =
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
        item.completion_phase = RDMA_CMQ_COMPLETION_NONE;
        item.reset_isolation_confirmed = 1'b0;
        item.recovery_required = 1'b1;
        item.completion = null;
        item.status = rdma_cmq_direct_status(RDMA_SC_OK);
        record_candidate.items.push_back(item);

        publish_item = new($sformatf("cmq_publish_item_%0d", i));
        publish_item.request_index = i;
        publish_item.slot_record = slot_snapshot;
        publish_item.command_key = command_key(authority_ticket);
        publish_item.entry_key = item.entry_key;
        publish_item.command_token = selected_token[4:0];
        preallocated_candidate.items.push_back(publish_item);
        dependencies.push_back(dependency_snapshot);
      end
    end

    if (!transaction_failed && record_candidate.items.size() == 0) begin
      batch_status = rdma_cmq_direct_status(RDMA_SC_OK);
      engine_lock.put(1);
      return;
    end

    if (!transaction_failed) begin
      final_sequence = publish_seq + record_candidate.items.size();
      final_pi = final_sequence % CMQ_DEPTH;
      final_polarity = (final_sequence / CMQ_DEPTH) & 1'b1;
      status = checked_handle_snapshot(
        cmq_snapshot.handle, "CMQ doorbell encoder",
        RDMA_SC_INVALID_STATE, doorbell_encode_target
      );
      if (status == null || !status.ok()) begin
        transaction_status = copy_submit_status_direct(
          status, "cmq_doorbell_handle_status"
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      doorbell_image = null;
      status = profile.encode_doorbell(
        doorbell_encode_target, final_pi, final_polarity, doorbell_image
      );
      if (!same_handle(doorbell_encode_target, cmq_snapshot.handle)) begin
        transaction_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ doorbell encoder changed its detached handle input"
        );
        transaction_failed = 1'b1;
      end
      else if (status == null || !status.ok()) begin
        transaction_status = (status == null) ? rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ doorbell encoding returned null status"
        ) : copy_submit_status_direct(status, "cmq_doorbell_encode_status");
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      status = doorbell_metadata_status(doorbell_image);
      if (status == null || !status.ok()) begin
        transaction_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          {"CMQ doorbell profile output is invalid: ",
           (status == null) ? "null status" : status.message}
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      status = checked_canonical_image_snapshot(
        doorbell_image, "CMQ doorbell", RDMA_SC_INVALID_STATE,
        doorbell_snapshot
      );
      if (status == null || !status.ok()) begin
        transaction_status = copy_submit_status_direct(
          status, "cmq_doorbell_snapshot_status"
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      status = doorbell_metadata_status(doorbell_snapshot);
      if (status == null || !status.ok()) begin
        transaction_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          {"CMQ doorbell snapshot metadata is invalid: ",
           (status == null) ? "null status" : status.message}
        );
        transaction_failed = 1'b1;
      end
    end

    minimum_remaining = 0;
    if (!transaction_failed) begin
      foreach (record_candidate.items[i]) begin
        if ($time >= record_candidate.items[i].ticket.absolute_deadline) begin
          transaction_status = rdma_cmq_direct_status(
            RDMA_SC_TIMEOUT,
            "CMQ batch deadline expired before publication"
          );
          transaction_failed = 1'b1;
          break;
        end
        remaining = record_candidate.items[i].ticket.absolute_deadline -
                    $time;
        if (minimum_remaining == 0 || remaining < minimum_remaining)
          minimum_remaining = remaining;
      end
    end

    doorbell_candidate = null;
    doorbell_snapshot_desc = null;
    if (!transaction_failed) begin
      doorbell_candidate = rdma_doorbell_desc::type_id::create(
        "cmq_batch_doorbell_candidate"
      );
      if (doorbell_candidate == null) begin
        transaction_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ doorbell descriptor construction failed"
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      doorbell_candidate.kind = RDMA_DOORBELL_CMQ_SQ;
      status = checked_function_snapshot(
        active_function, "CMQ doorbell descriptor", RDMA_SC_INVALID_STATE,
        doorbell_candidate.function_h
      );
      if (status == null || !status.ok()) begin
        transaction_status = copy_submit_status_direct(
          status, "cmq_doorbell_function_status"
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      status = checked_handle_snapshot(
        cmq_snapshot.handle, "CMQ doorbell descriptor",
        RDMA_SC_INVALID_STATE, doorbell_candidate.target_h
      );
      if (status == null || !status.ok()) begin
        transaction_status = copy_submit_status_direct(
          status, "cmq_doorbell_target_status"
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      doorbell_candidate.notify_bar_id = prepared_binding.notify_bar_id;
      doorbell_candidate.relative_offset =
        doorbell_snapshot.bar_target.value;
      doorbell_candidate.width = doorbell_snapshot.length;
      doorbell_candidate.endian = doorbell_snapshot.endian;
      doorbell_candidate.payload_image = doorbell_snapshot;
      doorbell_candidate.barrier_policy = RDMA_DB_BARRIER_DMA_MMIO;
      doorbell_candidate.write_combining_policy =
        RDMA_DB_WRITE_NON_COMBINING;
      doorbell_candidate.allow_merge = 1'b0;
      doorbell_candidate.merge_requested = 1'b0;
      doorbell_candidate.dependencies = dependencies;
      doorbell_candidate.timeout = minimum_remaining;
      doorbell_candidate.readback_policy = RDMA_DB_READBACK_NONE;
      status = checked_doorbell_desc_snapshot(
        doorbell_candidate, doorbell_snapshot_desc
      );
      if (status == null || !status.ok()) begin
        transaction_status = copy_submit_status_direct(
          status, "cmq_doorbell_descriptor_status"
        );
        transaction_failed = 1'b1;
      end
    end

    if (!transaction_failed) begin
      status = allocate_batch_identity_locked(
        record_candidate.function_identity, batch_key, batch_id
      );
      if (status == null || !status.ok()) begin
        transaction_status = copy_submit_status_direct(
          status, "cmq_batch_identity_status"
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      status = allocate_attempt_id_locked(attempt_id);
      if (status == null || !status.ok()) begin
        transaction_status = copy_submit_status_direct(
          status, "cmq_attempt_identity_status"
        );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      record_candidate.batch_key = batch_key;
      record_candidate.batch_id = batch_id;
      record_candidate.attempt_id = attempt_id;
      record_candidate.end_sequence = final_sequence;
      record_candidate.doorbell_image = doorbell_snapshot;
      record_candidate.final_pi = final_pi;
      record_candidate.final_polarity = final_polarity;
      preallocated_candidate.batch_key = batch_key;
      preallocated_candidate.attempt_id = attempt_id;
      preallocated_candidate.final_sequence = final_sequence;
      preallocated_candidate.profile_format_valid =
        staged_profile_format_valid;
      preallocated_candidate.profile_endian = staged_profile_endian;
      preallocated_candidate.profile_hardware_version =
        staged_profile_hardware_version;

      foreach (record_candidate.items[i]) begin
        rdma_cmq_batch_submission_item_record item;
        string body_tag;
        byte unsigned body_bytes[];
        bit classified_recovery;

        item = record_candidate.items[i];
        // batch identity 直到 admission 压缩完成后才分配；此处一次性把稳定
        // journal locator 写入尚未安装的预分配 slot，request_index 不参与定位。
        preallocated_candidate.items[i].slot_record.batch_key = batch_key;
        preallocated_candidate.items[i].slot_record.journal_item_index = i;
        if (!item.command.recovery_owner.is_legacy_unmigrated()) begin
          status = item.command.recovery_owner.freeze_for_journal(
            record_candidate.function_identity, attempt_id
          );
          if (status == null || !status.ok()) begin
            transaction_status = copy_submit_status_direct(
              status, "cmq_recovery_owner_freeze_status"
            );
            transaction_failed = 1'b1;
            break;
          end
        end
        item.recovery_owner = item.command.recovery_owner;
        status = item.command.validate_for_journal(
          record_candidate.function_identity, attempt_id
        );
        if (status == null || !status.ok()) begin
          transaction_status = copy_submit_status_direct(
            status, "cmq_journal_command_status"
          );
          transaction_failed = 1'b1;
          break;
        end
        item.dependency_replay_safe =
          item.dependency_mapping == backing_mapping &&
          item.dependency_offset ==
            longint'(item.slot_index) * CMQE_BYTES &&
          same_image_value(item.sqe_image, item.dependency_image) &&
          item.dma_context.function_h.generation ==
            record_candidate.function_identity.generation &&
          item.dma_context.reset_epoch ==
            record_candidate.function_identity.reset_epoch &&
          item.dependency_mapping.function_h.generation ==
            record_candidate.function_identity.generation &&
          item.dependency_mapping.reset_epoch ==
            record_candidate.function_identity.reset_epoch;
        status = profile.canonicalize_command_body(
          item.command.body, body_tag, body_bytes
        );
        if (status == null || !status.ok()) begin
          transaction_status = (status == null) ? rdma_cmq_direct_status(
            RDMA_SC_INVALID_STATE,
            "CMQ command body canonicalization returned null status"
          ) : copy_submit_status_direct(
            status, "cmq_command_canonical_status"
          );
          transaction_failed = 1'b1;
          break;
        end
        status = rdma_cmq_compute_item_digests(
          item.command, body_tag, body_bytes, item.ticket,
          item.recovery_owner, record_candidate.function_identity,
          item.dma_context, item.sqe_image, item.dependency_mapping,
          item.dependency_offset, item.dependency_image,
          item.image_digest, item.authority_digest
        );
        if (status == null || !status.ok()) begin
          transaction_status = (status == null) ? rdma_cmq_direct_status(
            RDMA_SC_INVALID_STATE,
            "CMQ item digest returned null status"
          ) : copy_submit_status_direct(status, "cmq_item_digest_status");
          transaction_failed = 1'b1;
          break;
        end
        status = rdma_cmq_classify_recovery_required(
          item.state, item.completion_phase, item.submission_effect,
          item.reset_isolation_confirmed,
          item.recovery_owner.is_legacy_unmigrated(), classified_recovery
        );
        if (status == null || !status.ok()) begin
          transaction_status = (status == null) ? rdma_cmq_direct_status(
            RDMA_SC_INVALID_STATE,
            "CMQ pending recovery classifier returned null status"
          ) : copy_submit_status_direct(
            status, "cmq_pending_recovery_status"
          );
          transaction_failed = 1'b1;
          break;
        end
        item.recovery_required = classified_recovery;
        request_indices.push_back(item.request_index);
        image_digests.push_back(item.image_digest);
        authority_digests.push_back(item.authority_digest);
      end
    end
    if (!transaction_failed) begin
      status = rdma_cmq_compute_batch_digest(
        record_candidate.function_identity, record_candidate.binding,
        record_candidate.cmq_h, record_candidate.doorbell_image,
        record_candidate.final_pi, record_candidate.final_polarity,
        record_candidate.start_sequence, record_candidate.end_sequence,
        request_indices, image_digests, authority_digests,
        record_candidate.batch_digest
      );
      if (status == null || !status.ok()) begin
        transaction_status = (status == null) ? rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE, "CMQ batch digest returned null status"
        ) : copy_submit_status_direct(status, "cmq_batch_digest_status");
        transaction_failed = 1'b1;
      end
    end

    observer = null;
    capability_key = "";
    if (!transaction_failed) begin
      capability_key = $sformatf(
        "%s|attempt=%016h", batch_key, attempt_id
      );
      observer = new("cmq_submission_mmio_observer");
      status = observer.configure(
        this, capability_key, batch_key, attempt_id, engine_incarnation
      );
      if (status == null || !status.ok() ||
          arm_observers.exists(capability_key)) begin
        transaction_status = (status == null || status.ok()) ?
          rdma_cmq_direct_status(
            RDMA_SC_INVALID_STATE,
            "CMQ MMIO observer construction or key collision failed"
          ) : copy_submit_status_direct(
            status, "cmq_observer_configure_status"
          );
        transaction_failed = 1'b1;
      end
    end
    if (!transaction_failed) begin
      status = install_submission_journal_locked(
        record_candidate, preallocated_candidate
      );
      if (status == null || !status.ok()) begin
        transaction_status = (status == null) ? rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ journal installation returned null status"
        ) : copy_submit_status_direct(
          status, "cmq_journal_installation_status"
        );
        transaction_failed = 1'b1;
      end
    end

    if (transaction_failed) begin
      if (transaction_status == null)
        transaction_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ batch transaction failed without a status"
        );
      foreach (results[i]) begin
        if (!local_result_finalized[i])
          results[i].status = copy_submit_status_direct(
            transaction_status,
            $sformatf("cmq_transaction_failure_item_%0d", i)
          );
      end
      batch_status = copy_submit_status_direct(
        transaction_status, "cmq_transaction_failure_batch"
      );
      engine_lock.put(1);
      return;
    end

    arm_observers[capability_key] = observer;
    fenced_batch_key = batch_key;
    submission_fence_reason =
      "CMQ observed submission awaits authentic MMIO classification";
    retained_record = submission_journal[batch_key];
    foreach (retained_record.items[i]) begin
      int unsigned token_index;

      token_index = retained_record.items[i].command_token;
      token_incarnation[token_index] =
        retained_record.items[i].ticket.command_id[63:5];
    end

    transport_result = null;
    transport.submit_observed(
      prepared_binding, doorbell_snapshot_desc, observer, transport_result
    );
    retained_record = submission_journal[batch_key];
    observer_armed = retained_record != null &&
                     retained_record.observer_armed;
    if (!observer_armed)
      arm_observers.delete(capability_key);

    observation_code = RDMA_SC_OK;
    observation_message = "";
    returned_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
    // 设计说明：operation status 与 attempted effect 是独立 transport 证据；只对
    // malformed 字段安装保守 fallback，避免 status 故障擦除有效 MMIO 证据，或
    // effect 故障把真实 operation failure/OK 改写为另一个状态。
    if (transport_result == null) begin
      operation_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "CMQ observed transport returned a null envelope"
      );
      observation_code = RDMA_SC_INVALID_STATE;
      observation_message =
        "CMQ observed transport envelope is missing";
    end
    else begin
      if (rdma_cmq_status_shape_valid(transport_result.status)) begin
        operation_status = copy_submit_status_direct(
          transport_result.status, "cmq_transport_operation_status"
        );
      end
      else begin
        operation_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ observed transport returned a malformed operation status"
        );
        observation_code = RDMA_SC_INVALID_STATE;
        observation_message =
          "CMQ observed transport operation status is malformed";
      end

      if (rdma_cmq_submission_effect_valid(
            transport_result.submission_effect
          )) begin
        returned_effect = transport_result.submission_effect;
      end
      else begin
        observation_code = RDMA_SC_INVALID_STATE;
        observation_message = (observation_message.len() == 0) ?
          "CMQ observed transport effect is malformed" :
          "CMQ observed transport status and effect are malformed";
      end
    end

    if (!observer_armed &&
        returned_effect == RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED) begin
      foreach (retained_record.items[i]) begin
        int unsigned request_index;

        request_index = retained_record.items[i].request_index;
        results[request_index].status = copy_submit_status_direct(
          operation_status,
          $sformatf("cmq_pre_rejected_item_%0d", request_index)
        );
        results[request_index].observation_status = rdma_cmq_direct_status(
          observation_code, observation_message
        );
        results[request_index].submission_effect =
          RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
        results[request_index].attempt_effect =
          RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
        results[request_index].completion_phase =
          RDMA_CMQ_COMPLETION_NONE;
        results[request_index].recovery_required = 1'b0;
      end
      status = remove_submission_journal_locked(batch_key);
      if (status == null || !status.ok()) begin
        batch_status = (status == null) ? rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ PRE rollback returned null status"
        ) : copy_submit_status_direct(status, "cmq_pre_rollback_status");
        engine_lock.put(1);
        return;
      end
      batch_status = rdma_cmq_direct_status(RDMA_SC_OK);
      engine_lock.put(1);
      return;
    end

    retry_safe = 1'b1;
    // 设计说明：dependency replayability 只证明数据可重放，不能替代恢复 authority；
    // journal 安装已验证 owner 完整 shape，因此这里的 LEGACY_UNMIGRATED workflow
    // 必然是精确 sentinel；它保留人工 reconciliation 兼容性但没有自动 retry 授权。
    foreach (retained_record.items[i]) begin
      rdma_cmq_batch_submission_item_record retry_item;

      retry_item = retained_record.items[i];
      if (retry_item == null || !retry_item.dependency_replay_safe)
        retry_safe = 1'b0;
      if (retry_item == null || retry_item.recovery_owner == null)
        retry_safe = 1'b0;
      else if (retry_item.recovery_owner.workflow ===
               RDMA_CMQ_WORKFLOW_LEGACY_UNMIGRATED)
        retry_safe = 1'b0;
    end
    if (observer_armed) begin
      retained_record.publication_retry_safe = 1'b0;
      if (returned_effect == RDMA_SUBMIT_EFFECT_MMIO_VISIBLE) begin
        retained_record.state = RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED;
        retained_record.submission_effect =
          RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
        retained_record.attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
      end
      else if (returned_effect == RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE) begin
        retained_record.state = RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS;
        retained_record.submission_effect =
          RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
        retained_record.attempt_effect =
          RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
      end
      else begin
        observation_code = RDMA_SC_INVALID_STATE;
        observation_message =
          "CMQ transport effect contradicts an authentic MMIO arm";
        retained_record.state = RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS;
        retained_record.submission_effect =
          RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
        retained_record.attempt_effect =
          (returned_effect == RDMA_SUBMIT_EFFECT_UNOBSERVED) ?
            RDMA_SUBMIT_EFFECT_UNOBSERVED :
            RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
      end
    end
    else begin
      retained_record.state =
        RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED;
      retained_record.publication_retry_safe = retry_safe;
      if (returned_effect inside {
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED
          }) begin
        retained_record.submission_effect = returned_effect;
        retained_record.attempt_effect = returned_effect;
      end
      else begin
        retained_record.submission_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
        retained_record.attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
        observation_code = RDMA_SC_INVALID_STATE;
        if (returned_effect inside {
              RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
              RDMA_SUBMIT_EFFECT_MMIO_VISIBLE
            }) begin
          retained_record.publication_retry_safe = 1'b0;
          observation_message =
            "CMQ transport reported MMIO effect without authentic arm";
        end
        else begin
          observation_message =
            "CMQ transport effect could not be observed after delegation";
        end
      end
    end

    foreach (retained_record.items[i]) begin
      rdma_cmq_batch_submission_item_record item;
      rdma_cmq_execution_result detached_result;
      bit classified_recovery;
      int unsigned request_index;

      item = retained_record.items[i];
      item.state = retained_record.state;
      item.submission_effect = retained_record.submission_effect;
      item.attempt_effect = retained_record.attempt_effect;
      item.completion_phase = observer_armed ?
        RDMA_CMQ_COMPLETION_PENDING : RDMA_CMQ_COMPLETION_NONE;
      item.status = copy_submit_status_direct(
        operation_status, $sformatf("cmq_journal_operation_%0d", i)
      );
      status = rdma_cmq_classify_recovery_required(
        item.state, item.completion_phase, item.submission_effect,
        item.reset_isolation_confirmed,
        item.recovery_owner.is_legacy_unmigrated(), classified_recovery
      );
      if (status == null || !status.ok()) begin
        observation_code = RDMA_SC_INVALID_STATE;
        observation_message = (status == null) ?
          "CMQ retained recovery classifier returned null status" :
          status.message;
        item.recovery_required = 1'b1;
      end
      else begin
        item.recovery_required = classified_recovery;
      end
      request_index = item.request_index;
      status = build_observed_result_locked(
        retained_record, item, observation_code, observation_message,
        detached_result
      );
      if (status == null || !status.ok() || detached_result == null) begin
        detached_result = new_submit_result_direct(
          $sformatf("cmq_observed_fallback_%0d", request_index)
        );
        detached_result.status = copy_submit_status_direct(
          item.status, $sformatf("cmq_observed_fallback_status_%0d", i)
        );
        detached_result.observation_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ observed result snapshot failed"
        );
        detached_result.submission_effect = item.submission_effect;
        detached_result.attempt_effect = item.attempt_effect;
        detached_result.completion_phase = item.completion_phase;
        detached_result.batch_key = retained_record.batch_key;
        detached_result.batch_id = retained_record.batch_id;
        detached_result.attempt_id = retained_record.attempt_id;
        detached_result.recovery_required = 1'b1;
      end
      results[request_index] = detached_result;
    end
    batch_status = rdma_cmq_direct_status(RDMA_SC_OK);
    engine_lock.put(1);
  endtask

  // 设计说明：恢复入口在同一 engine_lock 临界区内完成 locate、双图重算、完整值
  //   认证、candidate staging、唯一 CAS 与 transport 调用。这样第二个相同 expected
  //   attempt 只能在首个调用释放锁后观察新 attempt，并以 stale 结束。
  // 功能：对 retained fenced submission 执行 RETRY_PUBLISH，或消费 engine-minted
  //   READY reset proof 完成 CONFIRM_RESET_ISOLATION；CONFIRM 还会重验 retained
  //   proof-to-row ordered tuple 与 RESET_QUARANTINED/RESET_CANCELLED 生命周期。
  // 输入/输出及副作用：request 为 detached authority 图；results/status 入口立即
  //   初始化。RETRY 成功 CAS 后推进一次 attempt、登记 observer 并可能写 Host/MMIO；
  //   CONFIRM 不分配 attempt、不调用 I/O，只在全部重验后更新 confirmation/recovery bit。
  // 失败/边界：无法 locate/结构对齐返回空 results；其后 stale、action、digest、
  //   owner、proof/lifecycle、binding/mapping/fence/deadline/staging/collision 失败返回 aligned results，
  //   且在唯一 CAS 前不修改 counter、journal、preallocation、observer 或外部 I/O。
  task recover_submission_observed(
    input rdma_cmq_submission_recovery_request request,
    output rdma_cmq_execution_result results[],
    output rdma_status status
  );
    rdma_cmq_batch_submission_record record;
    rdma_cmq_preallocated_publish_batch preallocated;
    rdma_cmq_hw_profile profile_service;
    rdma_dma_mapping live_mapping_authority;
    rdma_doorbell_dependency dependencies[$];
    rdma_doorbell_desc doorbell_candidate;
    rdma_doorbell_desc doorbell_snapshot_desc;
    rdma_cmq_mmio_arm_observer observer;
    rdma_doorbell_submission_result transport_result;
    rdma_function_handle descriptor_function_source;
    rdma_handle descriptor_target;
    int unsigned request_indices[$];
    int unsigned journal_indices[$];
    rdma_cmq_journal_digest_t request_image_digests[$];
    rdma_cmq_journal_digest_t request_authority_digests[$];
    rdma_cmq_journal_digest_t journal_image_digests[$];
    rdma_cmq_journal_digest_t journal_authority_digests[$];
    rdma_cmq_journal_digest_t request_batch_digest;
    rdma_cmq_journal_digest_t journal_batch_digest;
    rdma_cmq_journal_digest_t request_proof_digest;
    rdma_cmq_journal_digest_t journal_proof_digest;
    rdma_status stage_status;
    rdma_status nested_status;
    rdma_status operation_status;
    rdma_status owner_status;
    rdma_status_code_e observation_code;
    rdma_submission_effect_e prior_cumulative;
    rdma_submission_effect_e current_attempt_effect;
    rdma_submission_effect_e cumulative_effect;
    rdma_submission_effect_e fold_evidence;
    longint unsigned candidate_attempt;
    time minimum_remaining;
    time remaining;
    string capability_key;
    string observation_message;
    bit observer_armed;
    bit retry_safe;
    bit classified_recovery;

    results = new[0];
    status = rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE, "CMQ recovery did not complete"
    );

    engine_lock.get(1);
    if (request == null ||
        request.get_object_type() !=
          rdma_cmq_submission_recovery_request::get_type() ||
        request.batch_key.len() == 0 ||
        !submission_journal.exists(request.batch_key)) begin
      status = journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request does not locate a retained batch"
      );
      engine_lock.put(1);
      return;
    end
    record = submission_journal[request.batch_key];
    if (record == null || record.batch_key != request.batch_key ||
        request.batch_id == 0 || request.batch_id != record.batch_id ||
        request.expected_function_identity == null ||
        record.function_identity == null ||
        !request.expected_function_identity.same_incarnation(
          record.function_identity
        ) || request.items.size() == 0 ||
        request.items.size() != record.items.size()) begin
      status = journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request does not structurally match the retained batch"
      );
      engine_lock.put(1);
      return;
    end
    foreach (request.items[i]) begin
      if (request.items[i] == null || record.items[i] == null ||
          request.items[i].ticket == null || record.items[i].ticket == null ||
          request.items[i].request_index != record.items[i].request_index) begin
        status = journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery item cardinality or order does not match"
        );
        engine_lock.put(1);
        return;
      end
    end

    stage_status = stage_recovery_results_locked(request, record, results);
    if (stage_status == null || !stage_status.ok()) begin
      status = (stage_status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery result staging returned null status"
      ) : journal_status(stage_status.code, stage_status.message);
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end
    if (request.expected_attempt_id != record.attempt_id) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE, "stale CMQ recovery attempt"
      );
      reject_recovery_results_locked(
        results, status.code, "stale CMQ recovery attempt"
      );
      engine_lock.put(1);
      return;
    end
    if ($isunknown(request.action) ||
        !(request.action inside {RDMA_CMQ_RECOVERY_RETRY_PUBLISH,
                                 RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION})) begin
      status = journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery action is invalid or unsupported"
      );
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end
    if (!journal_profile_by_batch.exists(record.batch_key) ||
        journal_profile_by_batch[record.batch_key] == null) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery retained profile authority is missing"
      );
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end
    profile_service = journal_profile_by_batch[record.batch_key];

    // request 图的每个 body 和 digest 仅从 request-owned 值重算；在所有 item
    // 与 batch 重算完成前不读取 journal carried digest 作为可信输入。
    foreach (request.items[i]) begin
      string body_tag;
      byte unsigned body_bytes[];
      rdma_cmq_journal_digest_t image_digest;
      rdma_cmq_journal_digest_t authority_digest;

      nested_status = profile_service.canonicalize_command_body(
        request.items[i].command.body, body_tag, body_bytes
      );
      if (nested_status != null && nested_status.ok())
        nested_status = rdma_cmq_compute_item_digests(
          request.items[i].command, body_tag, body_bytes,
          request.items[i].ticket, request.items[i].recovery_owner,
          request.expected_function_identity, request.items[i].dma_context,
          request.items[i].sqe_image,
          request.items[i].dependency_mapping,
          request.items[i].dependency_offset,
          request.items[i].dependency_image, image_digest, authority_digest
        );
      if (nested_status == null || !nested_status.ok()) begin
        status = (nested_status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery request item recomputation returned null status"
        ) : journal_status(nested_status.code, nested_status.message);
        reject_recovery_results_locked(results, status.code, status.message);
        engine_lock.put(1);
        return;
      end
      request_indices.push_back(request.items[i].request_index);
      request_image_digests.push_back(image_digest);
      request_authority_digests.push_back(authority_digest);
    end
    nested_status = rdma_cmq_compute_batch_digest(
      request.expected_function_identity, request.binding, request.cmq_h,
      request.doorbell_image, request.final_pi, request.final_polarity,
      request.start_sequence, request.end_sequence, request_indices,
      request_image_digests, request_authority_digests,
      request_batch_digest
    );
    if (nested_status == null || !nested_status.ok()) begin
      status = (nested_status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery request batch recomputation returned null status"
      ) : journal_status(nested_status.code, nested_status.message);
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end
    foreach (request.items[i]) begin
      if (request.items[i].image_digest !== request_image_digests[i] ||
          request.items[i].authority_digest !==
            request_authority_digests[i]) begin
        status = journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery request item carried digest is inconsistent"
        );
        reject_recovery_results_locked(results, status.code, status.message);
        engine_lock.put(1);
        return;
      end
    end
    if (request.batch_digest !== request_batch_digest) begin
      status = journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery request carried batch digest is inconsistent"
      );
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end

    // journal 图使用 retained exact profile 从 journal-owned 值独立重算；只有其
    // carried digest 自证后，才与 request recomputation 和完整值逐项比较。
    foreach (record.items[i]) begin
      string body_tag;
      byte unsigned body_bytes[];
      rdma_cmq_journal_digest_t image_digest;
      rdma_cmq_journal_digest_t authority_digest;

      nested_status = profile_service.canonicalize_command_body(
        record.items[i].command.body, body_tag, body_bytes
      );
      if (nested_status != null && nested_status.ok())
        nested_status = rdma_cmq_compute_item_digests(
          record.items[i].command, body_tag, body_bytes,
          record.items[i].ticket, record.items[i].recovery_owner,
          record.function_identity, record.items[i].dma_context,
          record.items[i].sqe_image, record.items[i].dependency_mapping,
          record.items[i].dependency_offset,
          record.items[i].dependency_image, image_digest, authority_digest
        );
      if (nested_status == null || !nested_status.ok()) begin
        status = (nested_status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery journal item recomputation returned null status"
        ) : journal_status(nested_status.code, nested_status.message);
        reject_recovery_results_locked(results, status.code, status.message);
        engine_lock.put(1);
        return;
      end
      journal_indices.push_back(record.items[i].request_index);
      journal_image_digests.push_back(image_digest);
      journal_authority_digests.push_back(authority_digest);
    end
    nested_status = rdma_cmq_compute_batch_digest(
      record.function_identity, record.binding, record.cmq_h,
      record.doorbell_image, record.final_pi, record.final_polarity,
      record.start_sequence, record.end_sequence, journal_indices,
      journal_image_digests, journal_authority_digests,
      journal_batch_digest
    );
    if (nested_status == null || !nested_status.ok()) begin
      status = (nested_status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery journal batch recomputation returned null status"
      ) : journal_status(nested_status.code, nested_status.message);
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end
    foreach (record.items[i]) begin
      if (record.items[i].image_digest !== journal_image_digests[i] ||
          record.items[i].authority_digest !==
            journal_authority_digests[i]) begin
        status = journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery journal item carried digest is inconsistent"
        );
        reject_recovery_results_locked(results, status.code, status.message);
        engine_lock.put(1);
        return;
      end
    end
    if (record.batch_digest !== journal_batch_digest) begin
      status = journal_status(
        RDMA_SC_INVALID_ARGUMENT,
        "CMQ recovery journal carried batch digest is inconsistent"
      );
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end

    foreach (request.items[i]) begin
      nested_status = validate_recovery_item_match_locked(
        request.items[i], record.items[i], request_image_digests[i],
        request_authority_digests[i], journal_image_digests[i],
        journal_authority_digests[i]
      );
      if (nested_status == null || !nested_status.ok()) begin
        status = (nested_status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery item full-value comparison returned null status"
        ) : journal_status(nested_status.code, nested_status.message);
        reject_recovery_results_locked(results, status.code, status.message);
        engine_lock.put(1);
        return;
      end
    end
    nested_status = validate_recovery_batch_match_locked(
      request, record, request_batch_digest, journal_batch_digest
    );
    if (nested_status == null || !nested_status.ok()) begin
      status = (nested_status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery batch full-value comparison returned null status"
      ) : journal_status(nested_status.code, nested_status.message);
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end

    foreach (request.items[i]) begin
      // A legacy sentinel (or an already resolved terminal item in a mixed
      // batch) carries no concrete recovery action.  CONFIRM must validate
      // only the still-unresolved concrete workflow evidence; RETRY keeps the
      // stricter all-item owner gate below.
      if (request.action == RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION &&
          (record.items[i].reset_isolation_confirmed ||
           !record.items[i].recovery_required))
        continue;
      owner_status = record.items[i].recovery_owner.validate_frozen(
        record.function_identity,
        record.items[i].recovery_owner.admission_attempt_id
      );
      if (owner_status != null && owner_status.ok())
        owner_status = request.items[i].recovery_owner.validate_frozen(
          record.function_identity,
          record.items[i].recovery_owner.admission_attempt_id
        );
      if (owner_status == null || !owner_status.ok() ||
          !record.items[i].recovery_owner.permits(request.action) ||
          !request.items[i].recovery_owner.permits(request.action)) begin
        status = (owner_status == null || owner_status.ok()) ?
          journal_status(
            RDMA_SC_INVALID_ARGUMENT,
            "CMQ recovery owner does not authorize this action"
          ) : journal_status(owner_status.code, owner_status.message);
        reject_recovery_results_locked(results, status.code, status.message);
        engine_lock.put(1);
        return;
      end
    end

    if (request.action == RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION) begin
      nested_status = validate_submission_record_locked(
        record, profile_service, 1'b0
      );
      if (nested_status == null || !nested_status.ok()) begin
        status = journal_status(
          RDMA_SC_INVALID_STATE,
          (nested_status == null) ?
            "CMQ reset confirmation journal validation returned null" :
            {"CMQ reset confirmation journal is invalid: ",
             nested_status.message}
        );
        reject_recovery_results_locked(results, status.code, status.message);
        engine_lock.put(1);
        return;
      end
      if (record.state != RDMA_CMQ_SUBMISSION_RESET_QUARANTINED) begin
        status = journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ reset confirmation requires a quarantined batch"
        );
        reject_recovery_results_locked(results, status.code, status.message);
        engine_lock.put(1);
        return;
      end
      begin
        bit concrete_pending;

        concrete_pending = 1'b0;
        foreach (record.items[i]) begin
          if (record.items[i].recovery_owner.is_legacy_unmigrated() ||
              record.items[i].reset_isolation_confirmed ||
              !record.items[i].recovery_required)
            continue;
          if (record.items[i].state !=
                RDMA_CMQ_SUBMISSION_RESET_QUARANTINED ||
              record.items[i].completion_phase !=
                RDMA_CMQ_COMPLETION_RESET_CANCELLED) begin
            status = journal_status(
              RDMA_SC_INVALID_STATE,
              "CMQ reset confirmation item lifecycle is not unresolved"
            );
            reject_recovery_results_locked(
              results, status.code, status.message
            );
            engine_lock.put(1);
            return;
          end
          concrete_pending = 1'b1;
        end
        if (!concrete_pending) begin
          status = journal_status(
            RDMA_SC_INVALID_STATE,
            "CMQ reset confirmation has no unresolved concrete owner"
          );
          reject_recovery_results_locked(results, status.code, status.message);
          engine_lock.put(1);
          return;
        end
      end
      if (request.reset_isolation_proof == null ||
          record.reset_isolation_proof == null ||
          record.reset_isolation_proof.state !=
            RDMA_CMQ_RESET_PROOF_READY ||
          request.reset_isolation_proof.state !=
            RDMA_CMQ_RESET_PROOF_READY) begin
        status = journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ reset isolation proof is absent or not READY"
        );
        reject_recovery_results_locked(results, status.code, status.message);
        engine_lock.put(1);
        return;
      end
      nested_status = rdma_cmq_compute_reset_proof_digest(
        request.reset_isolation_proof.proof_key,
        request.reset_isolation_proof.proof_id,
        request.reset_isolation_proof.batch_key,
        request.reset_isolation_proof.batch_id,
        request.reset_isolation_proof.attempt_id,
        request.reset_isolation_proof.engine_instance_id,
        request.reset_isolation_proof.engine_incarnation,
        request.reset_isolation_proof.isolated_identity,
        request.reset_isolation_proof.batch_digest,
        request.reset_isolation_proof.isolated_request_indices,
        request.reset_isolation_proof.isolated_image_digests,
        request.reset_isolation_proof.isolated_authority_digests,
        request.reset_isolation_proof.isolated_recovery_owners,
        request_proof_digest
      );
      if (nested_status != null && nested_status.ok())
        nested_status = rdma_cmq_compute_reset_proof_digest(
          record.reset_isolation_proof.proof_key,
          record.reset_isolation_proof.proof_id,
          record.reset_isolation_proof.batch_key,
          record.reset_isolation_proof.batch_id,
          record.reset_isolation_proof.attempt_id,
          record.reset_isolation_proof.engine_instance_id,
          record.reset_isolation_proof.engine_incarnation,
          record.reset_isolation_proof.isolated_identity,
          record.reset_isolation_proof.batch_digest,
          record.reset_isolation_proof.isolated_request_indices,
          record.reset_isolation_proof.isolated_image_digests,
          record.reset_isolation_proof.isolated_authority_digests,
          record.reset_isolation_proof.isolated_recovery_owners,
          journal_proof_digest
        );
      if (nested_status == null || !nested_status.ok() ||
          request.reset_isolation_proof.proof_digest !==
            request_proof_digest ||
          record.reset_isolation_proof.proof_digest !==
            journal_proof_digest ||
          request_proof_digest !== journal_proof_digest ||
          request.reset_isolation_proof.batch_digest !==
            request.batch_digest ||
          !same_reset_isolation_proof_value(
            request.reset_isolation_proof,
            record.reset_isolation_proof
          )) begin
        status = (nested_status == null || nested_status.ok()) ?
          journal_status(
            RDMA_SC_INVALID_ARGUMENT,
            "CMQ reset isolation proof authority does not match"
          ) : journal_status(nested_status.code, nested_status.message);
        reject_recovery_results_locked(results, status.code, status.message);
        engine_lock.put(1);
        return;
      end
      nested_status = validate_reset_isolation_proof_binding_locked(
        record.reset_isolation_proof, record
      );
      if (nested_status == null || !nested_status.ok()) begin
        status = (nested_status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ reset proof binding validation returned null status"
        ) : journal_status(nested_status.code, nested_status.message);
        reject_recovery_results_locked(results, status.code, status.message);
        engine_lock.put(1);
        return;
      end
      if (request.expected_attempt_id != record.attempt_id) begin
        status = journal_status(
          RDMA_SC_INVALID_STATE, "stale CMQ recovery attempt"
        );
        reject_recovery_results_locked(
          results, status.code, "stale CMQ recovery attempt"
        );
        engine_lock.put(1);
        return;
      end

      foreach (record.items[i]) begin
        if (!record.items[i].recovery_owner.is_legacy_unmigrated() &&
            !record.items[i].reset_isolation_confirmed &&
            record.items[i].recovery_required) begin
          record.items[i].reset_isolation_confirmed = 1'b1;
          record.items[i].recovery_required = 1'b0;
        end
        results[i].status = rdma_cmq_direct_status(RDMA_SC_OK);
        results[i].observation_status = rdma_cmq_direct_status(RDMA_SC_OK);
        results[i].submission_effect = record.items[i].submission_effect;
        results[i].attempt_effect = record.items[i].attempt_effect;
        results[i].completion_phase = record.items[i].completion_phase;
        results[i].attempt_id = record.attempt_id;
        results[i].recovery_required = record.items[i].recovery_required;
      end
      status = journal_status(RDMA_SC_OK);
      engine_lock.put(1);
      return;
    end

    if (engine_state != RDMA_CMQ_ENGINE_ACTIVE || prepared_binding == null ||
        dma_context == null || cmq_snapshot == null ||
        backing_mapping == null || transport == null || profile == null ||
        !same_journal_binding_value(prepared_binding, record.binding) ||
        !same_handle(cmq_snapshot.handle, record.cmq_h)) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery live Function or CMQ authority drifted"
      );
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end
    nested_status = validate_submission_record_locked(
      record, profile_service, 1'b0
    );
    if (nested_status == null || !nested_status.ok() ||
        record.state !=
          RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED ||
        record.observer_armed || !record.publication_retry_safe ||
        !(record.submission_effect inside {
          RDMA_SUBMIT_EFFECT_UNOBSERVED,
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED
        })) begin
      status = (nested_status == null || nested_status.ok()) ?
        journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery journal lifecycle is not retryable"
        ) : journal_status(nested_status.code, nested_status.message);
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end
    nested_status = mapping_authority_status(backing_mapping, dma_context);
    if (nested_status != null && nested_status.ok())
      nested_status = backing_mapping.snapshot_release_authority(
        live_mapping_authority
      );
    if (nested_status != null && nested_status.ok() &&
        live_mapping_authority != null)
      nested_status = backing_mapping.release_authority_status(
        live_mapping_authority
      );
    if (nested_status == null || !nested_status.ok() ||
        live_mapping_authority == null) begin
      status = (nested_status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery live mapping authority returned null status"
      ) : journal_status(nested_status.code, nested_status.message);
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end
    foreach (record.items[i]) begin
      if (record.items[i].state != record.state ||
          record.items[i].submission_effect != record.submission_effect ||
          record.items[i].completion_phase != RDMA_CMQ_COMPLETION_NONE ||
          record.items[i].reset_isolation_confirmed ||
          !record.items[i].recovery_required ||
          !record.items[i].dependency_replay_safe ||
          !same_journal_mapping_public_value(
            backing_mapping, record.items[i].dependency_mapping
          ) || !same_journal_mapping_public_value(
            backing_mapping, request.items[i].dependency_mapping
          )) begin
        status = journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery item mapping or replay authority is invalid"
        );
        reject_recovery_results_locked(results, status.code, status.message);
        engine_lock.put(1);
        return;
      end
      nested_status = backing_mapping.release_authority_status(
        request.items[i].dependency_mapping
      );
      if (nested_status != null && nested_status.ok())
        nested_status = backing_mapping.release_authority_status(
          record.items[i].dependency_mapping
        );
      if (nested_status == null || !nested_status.ok()) begin
        status = (nested_status == null) ? journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery item opaque mapping check returned null status"
        ) : journal_status(nested_status.code, nested_status.message);
        reject_recovery_results_locked(results, status.code, status.message);
        engine_lock.put(1);
        return;
      end
    end
    if (fenced_batch_key != record.batch_key ||
        submission_fence_reason.len() == 0) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery batch does not own the active submission fence"
      );
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end
    foreach (arm_observers[registered_key]) begin
      if (arm_observers[registered_key] == null ||
          arm_observers[registered_key].get_batch_key() == record.batch_key) begin
        status = journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery found a stale MMIO observer capability"
        );
        reject_recovery_results_locked(results, status.code, status.message);
        engine_lock.put(1);
        return;
      end
    end
    if (!preallocated_publish_batches.exists(record.batch_key)) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery preallocated publication row is missing"
      );
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end
    preallocated = preallocated_publish_batches[record.batch_key];
    if (preallocated == null ||
        preallocated.batch_key != record.batch_key ||
        preallocated.attempt_id != record.attempt_id ||
        preallocated.final_sequence != record.end_sequence ||
        preallocated.items.size() != record.items.size() ||
        record.start_sequence != publish_seq) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery preallocation is inconsistent with the journal"
      );
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end
    foreach (record.items[i]) begin
      rdma_cmq_preallocated_publish_item publish_item;

      publish_item = preallocated.items[i];
      if (publish_item == null || publish_item.slot_record == null ||
          publish_item.slot_record.expected == null ||
          publish_item.request_index != record.items[i].request_index ||
          publish_item.slot_record.ticket != record.items[i].ticket ||
          publish_item.slot_record.slot_sequence !=
            record.items[i].slot_sequence ||
          publish_item.slot_record.sq_index != record.items[i].slot_index ||
          publish_item.slot_record.sq_wrap != record.items[i].slot_wrap ||
          publish_item.slot_record.state != CMQ_SLOT_PUBLISHED ||
          publish_item.slot_record.batch_key != record.batch_key ||
          publish_item.slot_record.journal_item_index != i ||
          publish_item.command_token != record.items[i].command_token ||
          publish_item.command_key != command_key(record.items[i].ticket) ||
          publish_item.entry_key != record.items[i].entry_key ||
          record.items[i].slot_index >= CMQ_DEPTH ||
          slots[record.items[i].slot_index] != null ||
          token_in_use[record.items[i].command_token] ||
          command_registry.exists(publish_item.command_key) ||
          entry_registry.exists(publish_item.entry_key)) begin
        status = journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery preallocation or runtime registry collides"
        );
        reject_recovery_results_locked(results, status.code, status.message);
        engine_lock.put(1);
        return;
      end
    end
    if (attempt_id_counter == 64'hffff_ffff_ffff_ffff) begin
      status = journal_status(
        RDMA_SC_RESOURCE_EXHAUSTED, "CMQ attempt IDs are exhausted"
      );
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end
    candidate_attempt = attempt_id_counter + 1'b1;

    minimum_remaining = 0;
    foreach (record.items[i]) begin
      if ($isunknown(record.items[i].ticket.absolute_deadline)) begin
        status = journal_status(
          RDMA_SC_INVALID_ARGUMENT,
          "CMQ recovery ticket deadline contains X/Z"
        );
        reject_recovery_results_locked(results, status.code, status.message);
        engine_lock.put(1);
        return;
      end
      if (record.items[i].ticket.absolute_deadline == 0 ||
          record.items[i].ticket.absolute_deadline <= $time) begin
        status = journal_status(
          RDMA_SC_TIMEOUT,
          "CMQ recovery ticket deadline is not strictly in the future"
        );
        reject_recovery_results_locked(results, status.code, status.message);
        engine_lock.put(1);
        return;
      end
      remaining = record.items[i].ticket.absolute_deadline - $time;
      if (minimum_remaining == 0 || remaining < minimum_remaining)
        minimum_remaining = remaining;
    end

    dependencies.delete();
    foreach (record.items[i]) begin
      rdma_doorbell_dependency dependency;

      dependency = new($sformatf("cmq_recovery_dependency_%0d", i));
      dependency.dependency_id = record.items[i].slot_sequence + 1'b1;
      dependency.stage = RDMA_DB_DEP_QUEUE_CONTEXT;
      dependency.mapping = record.items[i].dependency_mapping;
      dependency.relative_offset = record.items[i].dependency_offset;
      dependency.image = record.items[i].dependency_image;
      dependency.ready = 1'b1;
      dependencies.push_back(dependency);
    end
    doorbell_candidate = make_recovery_doorbell_locked(
      "cmq_recovery_doorbell_candidate"
    );
    descriptor_function_source = record.binding.make_handle();
    if (doorbell_candidate == null || descriptor_function_source == null) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery doorbell descriptor construction failed"
      );
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end
    nested_status = checked_function_snapshot(
      descriptor_function_source, "CMQ recovery doorbell descriptor",
      RDMA_SC_INVALID_STATE, doorbell_candidate.function_h
    );
    if (nested_status != null && nested_status.ok())
      nested_status = checked_handle_snapshot(
        record.cmq_h, "CMQ recovery doorbell descriptor",
        RDMA_SC_INVALID_STATE, descriptor_target
      );
    if (nested_status == null || !nested_status.ok() ||
        descriptor_target == null) begin
      status = (nested_status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery descriptor nested snapshot returned null status"
      ) : journal_status(nested_status.code, nested_status.message);
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end
    doorbell_candidate.kind = RDMA_DOORBELL_CMQ_SQ;
    doorbell_candidate.target_h = descriptor_target;
    doorbell_candidate.notify_bar_id = record.binding.notify_bar_id;
    doorbell_candidate.relative_offset =
      record.doorbell_image.bar_target.value;
    doorbell_candidate.width = record.doorbell_image.length;
    doorbell_candidate.endian = record.doorbell_image.endian;
    doorbell_candidate.payload_image = record.doorbell_image;
    doorbell_candidate.barrier_policy = RDMA_DB_BARRIER_DMA_MMIO;
    doorbell_candidate.write_combining_policy =
      RDMA_DB_WRITE_NON_COMBINING;
    doorbell_candidate.allow_merge = 1'b0;
    doorbell_candidate.merge_requested = 1'b0;
    doorbell_candidate.dependencies = dependencies;
    doorbell_candidate.timeout = minimum_remaining;
    doorbell_candidate.readback_policy = RDMA_DB_READBACK_NONE;
    nested_status = checked_doorbell_desc_snapshot(
      doorbell_candidate, doorbell_snapshot_desc
    );
    if (nested_status == null || !nested_status.ok() ||
        doorbell_snapshot_desc == null) begin
      status = (nested_status == null) ? journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery descriptor validation returned null status"
      ) : journal_status(nested_status.code, nested_status.message);
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end

    capability_key = $sformatf(
      "%s|attempt=%016h", record.batch_key, candidate_attempt
    );
    observer = make_recovery_observer_locked(
      "cmq_recovery_mmio_observer"
    );
    if (observer == null) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery observer construction failed"
      );
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end
    nested_status = observer.configure(
      this, capability_key, record.batch_key, candidate_attempt,
      engine_incarnation
    );
    if (nested_status == null || !nested_status.ok() ||
        arm_observers.exists(capability_key)) begin
      status = (nested_status == null || nested_status.ok()) ?
        journal_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery observer configuration or key collision failed"
        ) : journal_status(nested_status.code, nested_status.message);
      reject_recovery_results_locked(results, status.code, status.message);
      engine_lock.put(1);
      return;
    end

    // 所有 fallible staging 已完成。以下连续赋值是唯一 locked CAS commit；
    // admission owner provenance 与 ticket absolute deadline 保持逐位不变。
    if (request.expected_attempt_id != record.attempt_id) begin
      status = journal_status(
        RDMA_SC_INVALID_STATE, "stale CMQ recovery attempt"
      );
      reject_recovery_results_locked(
        results, status.code, "stale CMQ recovery attempt"
      );
      engine_lock.put(1);
      return;
    end
    prior_cumulative = record.submission_effect;
    attempt_id_counter = candidate_attempt;
    record.attempt_id = candidate_attempt;
    record.state = RDMA_CMQ_SUBMISSION_PENDING_EFFECT;
    record.attempt_effect = RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
    record.observer_armed = 1'b0;
    record.publication_retry_safe = 1'b0;
    preallocated.attempt_id = candidate_attempt;
    foreach (record.items[i]) begin
      record.items[i].state = RDMA_CMQ_SUBMISSION_PENDING_EFFECT;
      record.items[i].attempt_effect =
        RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
      record.items[i].completion_phase = RDMA_CMQ_COMPLETION_NONE;
      record.items[i].completion = null;
      record.items[i].reset_isolation_confirmed = 1'b0;
      record.items[i].recovery_required = 1'b1;
      record.items[i].status = rdma_cmq_direct_status(RDMA_SC_OK);
      results[i].attempt_id = candidate_attempt;
      results[i].submission_effect = prior_cumulative;
      results[i].attempt_effect =
        RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
      results[i].completion_phase = RDMA_CMQ_COMPLETION_NONE;
      results[i].recovery_required = 1'b1;
    end
    arm_observers[capability_key] = observer;

    transport_result = null;
    transport.submit_observed(
      record.binding, doorbell_snapshot_desc, observer, transport_result
    );
    observer_armed = record.observer_armed;
    if (!observer_armed)
      arm_observers.delete(capability_key);

    observation_code = RDMA_SC_OK;
    observation_message = "";
    current_attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
    if (transport_result == null) begin
      operation_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "CMQ recovery transport returned a null envelope"
      );
      observation_code = RDMA_SC_INVALID_STATE;
      observation_message = "CMQ recovery transport envelope is missing";
    end
    else begin
      if (rdma_cmq_status_shape_valid(transport_result.status))
        operation_status = copy_submit_status_direct(
          transport_result.status, "cmq_recovery_operation_status"
        );
      else begin
        operation_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "CMQ recovery transport operation status is malformed"
        );
        observation_code = RDMA_SC_INVALID_STATE;
        observation_message =
          "CMQ recovery transport operation status is malformed";
      end
      if (rdma_cmq_submission_effect_valid(
            transport_result.submission_effect
          ))
        current_attempt_effect = transport_result.submission_effect;
      else begin
        current_attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
        observation_code = RDMA_SC_INVALID_STATE;
        observation_message =
          "CMQ recovery transport effect is malformed";
      end
    end

    retry_safe = 1'b1;
    if (observer_armed) begin
      record.publication_retry_safe = 1'b0;
      if (current_attempt_effect == RDMA_SUBMIT_EFFECT_MMIO_VISIBLE) begin
        record.state = RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED;
        fold_evidence = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
      end
      else begin
        record.state = RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS;
        fold_evidence = RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
        if (current_attempt_effect !=
              RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE &&
            current_attempt_effect != RDMA_SUBMIT_EFFECT_UNOBSERVED) begin
          current_attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
          observation_code = RDMA_SC_INVALID_STATE;
          observation_message =
            "CMQ recovery transport effect contradicts authentic MMIO arm";
        end
      end
      if (!rdma_cmq_fold_attempt_effect(
            record.submission_effect, fold_evidence, cumulative_effect
          ))
        cumulative_effect = RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
    end
    else begin
      record.state = RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED;
      if (!(current_attempt_effect inside {
            RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED,
            RDMA_SUBMIT_EFFECT_UNOBSERVED,
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
            RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED
          })) begin
        current_attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
        retry_safe = 1'b0;
        observation_code = RDMA_SC_INVALID_STATE;
        observation_message =
          "CMQ recovery transport reported MMIO without authentic arm";
      end
      if (!rdma_cmq_fold_attempt_effect(
            prior_cumulative, current_attempt_effect, cumulative_effect
          ))
        cumulative_effect = prior_cumulative;
      record.publication_retry_safe = retry_safe;
    end
    record.submission_effect = cumulative_effect;
    record.attempt_effect = current_attempt_effect;

    foreach (record.items[i]) begin
      record.items[i].state = record.state;
      record.items[i].submission_effect = cumulative_effect;
      record.items[i].attempt_effect = current_attempt_effect;
      record.items[i].completion_phase = observer_armed ?
        RDMA_CMQ_COMPLETION_PENDING : RDMA_CMQ_COMPLETION_NONE;
      record.items[i].status = copy_submit_status_direct(
        operation_status, $sformatf("cmq_recovery_journal_status_%0d", i)
      );
      nested_status = rdma_cmq_classify_recovery_required(
        record.items[i].state, record.items[i].completion_phase,
        record.items[i].submission_effect,
        record.items[i].reset_isolation_confirmed,
        record.items[i].recovery_owner.is_legacy_unmigrated(),
        classified_recovery
      );
      if (nested_status == null || !nested_status.ok()) begin
        classified_recovery = 1'b1;
        observation_code = RDMA_SC_INVALID_STATE;
        observation_message = (nested_status == null) ?
          "CMQ recovery classifier returned null status" :
          nested_status.message;
      end
      record.items[i].recovery_required = classified_recovery;
      results[i].status = copy_submit_status_direct(
        operation_status, $sformatf("cmq_recovery_result_status_%0d", i)
      );
      results[i].observation_status = rdma_cmq_direct_status(
        observation_code, observation_message
      );
      results[i].submission_effect = cumulative_effect;
      results[i].attempt_effect = current_attempt_effect;
      results[i].completion_phase = record.items[i].completion_phase;
      results[i].attempt_id = candidate_attempt;
      results[i].recovery_required = classified_recovery;
    end
    status = journal_status(RDMA_SC_OK);
    engine_lock.put(1);
  endtask

  // 功能：把一个 command 包装为恰好一次 observed batch 调用并返回其唯一结果。
  // 输入/输出及副作用：command 为输入，result 为输出；所有 journal、transport
  //   与 fence 副作用完全由 submit_batch_observed() 产生。
  // 失败/边界：batch 返回错位/null 结果时发布非空 INVALID_STATE fallback；
  //   不做第二次提交，也不写共享 last_* 证据。
  task submit_observed(
    input rdma_cmq_command_desc command,
    output rdma_cmq_execution_result result
  );
    rdma_cmq_command_desc commands[];
    rdma_cmq_execution_result results[];
    rdma_status batch_status;

    result = new_submit_result_direct("cmq_single_observed_fallback");
    commands = new[1];
    commands[0] = command;
    submit_batch_observed(commands, results, batch_status);
    if (results.size() != 1 || results[0] == null) begin
      result.status = (batch_status == null) ? rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "CMQ one-item observed batch returned no result"
      ) : copy_submit_status_direct(
        batch_status, "cmq_single_observed_batch_status"
      );
      return;
    end
    result = results[0];
  endtask

  // 功能：把 observed batch 的 ticket/operation status 单向投影到 legacy 输出，
  //   transport 与 journal transaction 仍只执行一次。
  // 输入/输出及副作用：requests 为输入；tickets/item_statuses 与请求等长，
  //   batch_status 直接承接 observed orchestration 状态。
  // 失败/边界：result/ticket/status 形状异常时该项返回 INVALID_STATE 与 null ticket；
  //   投影不重试、不反向修改 observed result 或 journal。
  task submit_batch(
    input rdma_cmq_command_desc requests[],
    output rdma_cmq_ticket tickets[],
    output rdma_status item_statuses[],
    output rdma_status batch_status
  );
    rdma_cmq_execution_result observed_results[];

    submit_batch_observed(requests, observed_results, batch_status);
    tickets = new[requests.size()];
    item_statuses = new[requests.size()];
    foreach (tickets[i]) begin
      rdma_cmq_nonfatal_snapshot_context snapshot_context;
      string failure_reason;

      tickets[i] = null;
      item_statuses[i] = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "CMQ legacy batch observed result is missing"
      );
      if (i >= observed_results.size() || observed_results[i] == null)
        continue;
      item_statuses[i] = copy_submit_status_direct(
        observed_results[i].status,
        $sformatf("cmq_legacy_item_status_%0d", i)
      );
      snapshot_context = new();
      if (!snapshot_context.try_snapshot_optional_ticket(
            observed_results[i].ticket, tickets[i], failure_reason
          )) begin
        tickets[i] = null;
        item_statuses[i] = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          {"CMQ legacy ticket projection failed: ", failure_reason}
        );
      end
    end
    if (batch_status == null)
      batch_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "CMQ observed batch returned null orchestration status"
      );
  endtask

  // 功能：把单条 observed result 单向投影为 legacy ticket/status，保证只调用
  //   submit_observed() 一次且不重新推断 transport effect。
  // 输入/输出及副作用：request 为输入；ticket/status 为 detached legacy 输出；
  //   journal/fence/runtime 副作用由 observed 入口原样保留。
  // 失败/边界：result/status/ticket snapshot 异常时返回 null ticket 与独立
  //   INVALID_STATE；operation failure 原样返回且不以 batch 状态覆盖。
  task submit(
    input rdma_cmq_command_desc request,
    output rdma_cmq_ticket ticket,
    output rdma_status status
  );
    rdma_cmq_execution_result observed_result;
    rdma_cmq_nonfatal_snapshot_context snapshot_context;
    string failure_reason;

    ticket = null;
    status = rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE, "CMQ legacy submit did not complete"
    );
    submit_observed(request, observed_result);
    if (observed_result == null) begin
      status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE, "CMQ observed submit returned null result"
      );
      return;
    end
    status = copy_submit_status_direct(
      observed_result.status, "cmq_legacy_submit_status"
    );
    snapshot_context = new();
    if (!snapshot_context.try_snapshot_optional_ticket(
          observed_result.ticket, ticket, failure_reason
        )) begin
      ticket = null;
      status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        {"CMQ legacy submit ticket projection failed: ", failure_reason}
      );
    end
  endtask

  // 功能：在 rdma_cmq_engine 中，expire 根据当前证据转换事务或恢复状态，并保持重试、复位和所有权边界一致。
  // 输入/输出及副作用：completions（输出）、status（输出）；expire 驱动下游事务，并写入 completions、status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：expire 失败或超时通过 completions、status 明确发布；该路径不隐式重试，也不转移未声明资源。
  task expire(
    output rdma_cmq_completion completions[$],
    output rdma_status status
  );
    completions.delete();
    status = invalid_state("CMQ expire did not complete");
    engine_lock.get(1);
    if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
      status = invalid_state("CMQ expire requires an ACTIVE engine");
      engine_lock.put(1);
      return;
    end
    status = expire_locked();
    while (terminal_fifo.size() != 0)
      completions.push_back(terminal_fifo.pop_front());
    engine_lock.put(1);
  endtask

  // 功能：按 CQ consumer 顺序读取并解码 ready CQE，把正常完成或
  //   same-incarnation 超时晚到完成先写入 exact retained journal item，
  //   再发布 delivery FIFO/诊断并推进 CQ/retire cursor。
  // 输入/输出及副作用：status 输出整个 poll 的首个失败或 OK；
  //   函数读 Host-memory CQ backing/调用 profile，成功后更新 journal、
  //   terminal/diagnostic/late FIFO、command/token/entry/slot 账本及 consumer cursor。
  // 失败/边界：engine/mapping/profile/ledger 不完整、CQ read/decode 失败、
  //   owner/opcode/slot/token/locator 不匹配或 journal snapshot/reducer 失败时，
  //   不消费当前 CQE，不发布该项 FIFO；not-ready CQE 正常返回 OK。
  protected task poll_locked(output rdma_status status);
    byte data[];
    rdma_status read_status;
    rdma_status inspect_status;
    rdma_status validation_status;
    rdma_status completion_status;
    rdma_status diagnostic_status;
    rdma_status retirement_status;
    rdma_hw_image raw_cqe;
    rdma_hw_image raw_snapshot;
    rdma_cmq_decoded_cqe decoded;
    rdma_cmq_slot_record record;
    rdma_cmq_completion completion;
    rdma_cmq_batch_submission_record journal_batch;
    rdma_cmq_batch_submission_item_record journal_item;
    rdma_cmq_completion journal_completion;
    rdma_cmq_diagnostic diagnostic;
    rdma_cmq_submission_state_e reduced_batch_state;
    longint unsigned read_offset;
    int unsigned cq_index;
    int unsigned token_index;
    bit expected_owner;
    bit ready;
    bit recovery_required;
    string hardware_key;
    string software_key;
    longint unsigned ledger_used;
    longint unsigned prospective_retire_seq;

    status = invalid_state("CMQ poll did not complete");
    if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
      status = invalid_state("CMQ poll requires an ACTIVE engine");
      return;
    end
    if (prepared_binding == null || backing_mapping == null ||
        host_mem == null || profile == null) begin
      status = invalid_state("CMQ ACTIVE polling authority is missing");
      return;
    end
    status = mapping_authority_status(backing_mapping, dma_context);
    if (!status.ok())
      return;
    status = poll_ledger_status(ledger_used);
    if (!status.ok())
      return;
    if (ledger_used == 0 && !profile_image_format_valid) begin
      status = rdma_status::success();
      return;
    end

    status = rdma_status::success();
    while (status.ok()) begin
      cq_index = cq_consume_seq % CMQ_DEPTH;
      read_offset = CQ_OFFSET + (longint'(cq_index) * CMQE_BYTES);
      data = new[0];
      read_status = host_mem.read(
        backing_mapping, read_offset, CMQE_BYTES, data
      );
      if (read_status == null) begin
        status = invalid_state("CMQ CQ backing read returned null status");
        break;
      end
      if (!read_status.ok()) begin
        status = rdma_cmq_clone_status_value(read_status);
        break;
      end
      status = make_raw_cqe_image(data, raw_cqe);
      if (!status.ok())
        break;
      status = checked_image_snapshot(
        raw_cqe, "CMQ CQE inspection", RDMA_SC_INVALID_STATE,
        raw_snapshot
      );
      if (!status.ok())
        break;
      expected_owner = !((cq_consume_seq / CMQ_DEPTH) & 1'b1);
      ready = 1'b0;
      decoded = null;
      inspect_status = profile.inspect_cqe(
        raw_cqe, expected_owner, ready, decoded
      );
      if (!same_image_value(raw_cqe, raw_snapshot)) begin
        status = invalid_state("CMQ profile changed its raw CQE input");
        break;
      end
      if (inspect_status == null) begin
        status = poison(
          RDMA_CMQ_DIAG_MALFORMED_CQE,
          "CMQ profile inspection returned null status", raw_snapshot
        );
        break;
      end
      if (!inspect_status.ok()) begin
        if (inspect_status.code inside {
              RDMA_SC_CODEC_ERROR, RDMA_SC_UNSUPPORTED_OPCODE
            })
          status = poison(
            RDMA_CMQ_DIAG_MALFORMED_CQE,
            inspect_status.message, raw_snapshot
          );
        else
          status = rdma_cmq_clone_status_value(inspect_status);
        break;
      end
      if (!ready) begin
        status = rdma_status::success();
        break;
      end
      if (decoded == null || decoded.wqe_index >= CMQ_DEPTH) begin
        status = poison(
          RDMA_CMQ_DIAG_MALFORMED_CQE,
          "CMQ profile returned an invalid decoded CQE", raw_snapshot
        );
        break;
      end

      hardware_key = entry_key(decoded.wqe_index, decoded.wqe_wrap);
      if (!entry_registry.exists(hardware_key)) begin
        status = poison(
          RDMA_CMQ_DIAG_UNKNOWN_CQE,
          "CMQ decoded CQE has no registered entry", raw_snapshot
        );
        break;
      end
      record = entry_registry[hardware_key];
      if (record == null || slots[decoded.wqe_index] == null ||
          slots[decoded.wqe_index] != record ||
          record.sq_index != decoded.wqe_index ||
          record.sq_wrap != decoded.wqe_wrap ||
          record.ticket == null || record.expected == null ||
          record.ticket.sq_index != record.sq_index ||
          record.ticket.sq_wrap != record.sq_wrap ||
          record.ticket.slot_sequence != record.slot_sequence ||
          record.ticket.command_id[4:0] != record.command_token ||
          !(record.state inside {
            CMQ_SLOT_PUBLISHED,
            CMQ_SLOT_TIMED_OUT_QUARANTINED
          })) begin
        status = poison(
          RDMA_CMQ_DIAG_POISON,
          "CMQ decoded CQE entry ledger is inconsistent", raw_snapshot
        );
        break;
      end
      if (decoded.command_status == null) begin
        status = poison(
          RDMA_CMQ_DIAG_MALFORMED_CQE,
          "CMQ profile returned a null decoded command status",
          raw_snapshot, record.ticket
        );
        break;
      end
      validation_status = decoded.validate();
      if (validation_status == null || !validation_status.ok()) begin
        status = poison(
          RDMA_CMQ_DIAG_MALFORMED_CQE,
          "CMQ decoded CQE validation failed", raw_snapshot,
          record.ticket
        );
        break;
      end
      status = decoded_status_contract(decoded);
      if (!status.ok()) begin
        status = poison(
          RDMA_CMQ_DIAG_MALFORMED_CQE, status.message, raw_snapshot,
          record.ticket
        );
        break;
      end
      if (record.expected.hardware_opcode != decoded.hardware_opcode) begin
        status = poison(
          RDMA_CMQ_DIAG_MALFORMED_CQE,
          "CMQ decoded CQE opcode does not match command", raw_snapshot,
          record.ticket
        );
        break;
      end
      software_key = command_key(record.ticket);
      if (cq_consume_seq == 64'hffff_ffff_ffff_ffff) begin
        status = poison(
          RDMA_CMQ_DIAG_POISON,
          "CMQ completion consumer counter overflows", raw_snapshot,
          record.ticket
        );
        break;
      end

      if (record.state == CMQ_SLOT_PUBLISHED) begin
        if (!command_registry.exists(software_key) ||
            command_registry[software_key] != record) begin
          status = poison(
            RDMA_CMQ_DIAG_POISON,
            "CMQ decoded CQE command registry is inconsistent",
            raw_snapshot, record.ticket
          );
          break;
        end
        token_index = record.command_token;
        if (token_index >= CMQ_DEPTH || !token_in_use[token_index] ||
            token_incarnation[token_index] !=
              record.ticket.command_id[63:5]) begin
          status = poison(
            RDMA_CMQ_DIAG_POISON,
            "CMQ decoded CQE command token is inconsistent", raw_snapshot,
            record.ticket
          );
          break;
        end
      end
      else begin
        if (command_registry.exists(software_key)) begin
          status = poison(
            RDMA_CMQ_DIAG_POISON,
            "CMQ quarantined command remains in the command registry",
            raw_snapshot, record.ticket
          );
          break;
        end
        token_index = record.command_token;
        if (token_index >= CMQ_DEPTH || !token_in_use[token_index] ||
            token_incarnation[token_index] !=
              record.ticket.command_id[63:5]) begin
          status = poison(
            RDMA_CMQ_DIAG_POISON,
            "CMQ quarantined completion token incarnation is inconsistent",
            raw_snapshot, record.ticket
          );
          break;
        end
      end
      retirement_status = prospective_retirement_status(
        record, prospective_retire_seq
      );
      if (retirement_status == null || !retirement_status.ok()) begin
        status = poison(
          RDMA_CMQ_DIAG_POISON,
          (retirement_status == null) ?
            "CMQ prospective retirement returned null status" :
            retirement_status.message,
          raw_snapshot
        );
        break;
      end

      if (record.state == CMQ_SLOT_PUBLISHED) begin
        completion_status = make_polled_completion(
          record, raw_snapshot, decoded, completion
        );
        if (completion_status == null || !completion_status.ok() ||
            completion == null) begin
          status = (completion_status == null) ?
            invalid_state("CMQ completion construction returned null status") :
            completion_status;
          break;
        end
        completion_status = stage_runtime_journal_transition_locked(
          record, completion, RDMA_CMQ_SUBMISSION_COMPLETED,
          RDMA_CMQ_COMPLETION_TERMINAL, journal_batch, journal_item,
          journal_completion, recovery_required, reduced_batch_state
        );
        if (completion_status == null || !completion_status.ok()) begin
          status = (completion_status == null) ?
            invalid_state(
              "CMQ normal completion journal staging returned null status"
            ) : completion_status;
          break;
        end
        commit_runtime_journal_transition_locked(
          journal_batch, journal_item, journal_completion,
          RDMA_CMQ_SUBMISSION_COMPLETED, RDMA_CMQ_COMPLETION_TERMINAL,
          recovery_required, reduced_batch_state
        );
        terminal_fifo.push_back(completion);
        command_registry.delete(software_key);
        token_in_use[token_index] = 1'b0;
        record.state = CMQ_SLOT_COMPLETED;
      end
      else begin
        diagnostic_status = make_late_diagnostic(
          record, raw_snapshot, diagnostic
        );
        if (diagnostic_status == null || !diagnostic_status.ok() ||
            diagnostic == null) begin
          status = (diagnostic_status == null) ?
            invalid_state("CMQ late diagnostic returned null status") :
            diagnostic_status;
          break;
        end
        completion_status = make_polled_completion(
          record, raw_snapshot, decoded, completion
        );
        if (completion_status == null || !completion_status.ok() ||
            completion == null) begin
          status = (completion_status == null) ?
            invalid_state(
              "CMQ late final completion construction returned null status"
            ) : completion_status;
          break;
        end
        completion_status = stage_runtime_journal_transition_locked(
          record, completion, RDMA_CMQ_SUBMISSION_LATE_COMPLETED,
          RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY, journal_batch, journal_item,
          journal_completion, recovery_required, reduced_batch_state
        );
        if (completion_status == null || !completion_status.ok()) begin
          status = (completion_status == null) ?
            invalid_state(
              "CMQ late completion journal staging returned null status"
            ) : completion_status;
          break;
        end
        commit_runtime_journal_transition_locked(
          journal_batch, journal_item, journal_completion,
          RDMA_CMQ_SUBMISSION_LATE_COMPLETED,
          RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY,
          recovery_required, reduced_batch_state
        );
        diagnostic_fifo.push_back(diagnostic);
        late_final_fifo.push_back(completion);
        token_in_use[token_index] = 1'b0;
        record.state = CMQ_SLOT_LATE_COMPLETED;
      end
      cq_consume_seq++;
      commit_retired_prefix(prospective_retire_seq);
      if (publish_seq == retire_seq)
        break;
    end

  endtask

  // 功能：在 rdma_cmq_engine 中，poll 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：completions（输出）、diagnostics（输出）、status（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为 detached
  //   快照，读取不取得外部资源所有权。
  // 失败/边界：poll 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  task poll(
    output rdma_cmq_completion completions[$],
    output rdma_cmq_diagnostic diagnostics[$],
    output rdma_status status
  );
    rdma_status expiry_status;

    completions.delete();
    diagnostics.delete();
    status = invalid_state("CMQ poll did not complete");
    engine_lock.get(1);
    if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
      status = invalid_state("CMQ poll requires an ACTIVE engine");
      while (diagnostic_fifo.size() != 0)
        diagnostics.push_back(diagnostic_fifo.pop_front());
      late_final_fifo.delete();
      engine_lock.put(1);
      return;
    end
    expiry_status = expire_locked();
    if (expiry_status == null)
      status = invalid_state("CMQ expiry helper returned null status");
    else if (!expiry_status.ok())
      status = expiry_status;
    else begin
      poll_locked(status);
    end
    while (terminal_fifo.size() != 0)
      completions.push_back(terminal_fifo.pop_front());
    while (diagnostic_fifo.size() != 0)
      diagnostics.push_back(diagnostic_fifo.pop_front());
    late_final_fifo.delete();
    engine_lock.put(1);
  endtask

  // 功能：控制 wait_for 对应的等待、异常或同步边界，按超时/捕获结果返回状态，不吞掉原始错误。
  // 输入/输出及副作用：ticket（输入）、completion（输出）、status（输出）；wait_for 驱动下游事务，并写入 completion、status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：wait_for 超时或异常必须返回原始错误证据；不得无限等待或跳过同步边界。
  task wait_for(
    rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    rdma_status validation_status;
    rdma_status expiry_status;
    rdma_status poll_status;
    rdma_status snapshot_status;
    rdma_cmq_ticket ticket_snapshot;
    rdma_cmq_batch_submission_record frozen_batch;
    rdma_cmq_batch_submission_item_record frozen_item;
    rdma_cmq_batch_submission_record current_batch;
    rdma_cmq_batch_submission_item_record current_item;
    rdma_cmq_completion detached_completion;
    rdma_function_identity frozen_identity;
    rdma_function_identity current_identity;
    int unsigned frozen_item_index;
    int unsigned current_item_index;
    int fifo_index;
    time remaining;
    time wait_time;
    bit journal_located;
    bit fallback_outstanding;

    completion = null;
    status = invalid_state("CMQ wait did not complete");
    engine_lock.get(1);
    if (ticket == null) begin
      status = invalid_argument("CMQ wait ticket is null");
      engine_lock.put(1);
      return;
    end
    validation_status = ticket_trust_status(ticket);
    if (validation_status == null || !validation_status.ok()) begin
      status = invalid_argument("CMQ wait ticket is invalid");
      engine_lock.put(1);
      return;
    end
    validation_status = checked_completion_ticket_snapshot(
      ticket, ticket_snapshot
    );
    if (validation_status == null || !validation_status.ok()) begin
      status = (validation_status == null) ?
        invalid_state("CMQ wait ticket snapshot returned null status") :
        validation_status;
      engine_lock.put(1);
      return;
    end

    // 首次锁内定位必须先冻结 retained row；ticket handle 后续可被 caller
    // 改写，waiter 只使用此 canonical snapshot。
    validation_status = locate_journal_item_by_ticket_locked(
      ticket_snapshot, frozen_batch, frozen_item, frozen_item_index
    );
    journal_located = validation_status != null && validation_status.ok();
    fallback_outstanding = 1'b0;
    if (journal_located) begin
      if (frozen_batch.function_identity == null ||
          !rdma_cmq_try_snapshot_identity_direct(
            frozen_batch.function_identity, frozen_identity
          )) begin
        status = invalid_state("CMQ wait retained Function snapshot failed");
        engine_lock.put(1);
        return;
      end
      if (frozen_item == null || frozen_item.ticket == null) begin
        status = invalid_state("CMQ wait retained item is incomplete");
        engine_lock.put(1);
        return;
      end
      if (frozen_item.state inside {
            RDMA_CMQ_SUBMISSION_STAGED,
            RDMA_CMQ_SUBMISSION_PENDING_EFFECT
          }) begin
        status = invalid_state("CMQ wait ticket is not observable yet");
        engine_lock.put(1);
        return;
      end
      if (frozen_item.state == RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED) begin
        status = invalid_state("CMQ wait ticket was not published");
        engine_lock.put(1);
        return;
      end
      if (frozen_item.completion != null &&
          frozen_item.completion_phase inside {
            RDMA_CMQ_COMPLETION_TERMINAL,
            RDMA_CMQ_COMPLETION_TIMEOUT,
            RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY,
            RDMA_CMQ_COMPLETION_RESET_CANCELLED
          }) begin
        // A FIFO row is delivery order only.  Snapshot from journal first, then
        // consume the matching FIFO row so another ticket remains untouched.
        snapshot_status = snapshot_retained_completion_locked(
          frozen_batch, frozen_item, detached_completion
        );
        if (snapshot_status == null || !snapshot_status.ok()) begin
          status = (snapshot_status == null) ? invalid_state(
            "CMQ wait retained completion snapshot returned null status"
          ) : snapshot_status;
          engine_lock.put(1);
          return;
        end
        fifo_index = terminal_index(ticket_snapshot);
        if (fifo_index >= 0)
          terminal_fifo.delete(fifo_index);
        completion = detached_completion;
        status = copy_submit_status_direct(
          detached_completion.status, "cmq_wait_terminal_status"
        );
        if (status == null)
          status = invalid_state("CMQ wait terminal status snapshot failed");
        engine_lock.put(1);
        return;
      end
      if (!(frozen_item.state inside {
            RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
            RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
          }) || frozen_item.completion_phase !=
            RDMA_CMQ_COMPLETION_PENDING) begin
        status = invalid_state("CMQ wait retained lifecycle is not pending");
        engine_lock.put(1);
        return;
      end
      if (engine_state != RDMA_CMQ_ENGINE_ACTIVE ||
          engine_incarnation != frozen_batch.engine_incarnation) begin
        status = invalid_state("CMQ wait pending ticket belongs to old engine");
        engine_lock.put(1);
        return;
      end
    end
    else begin
      // Compatibility for pre-journal test/facade completions.  This fallback
      // is intentionally limited to the current active runtime and never lets
      // a post-reset ticket inspect a newly prepared backing.
      if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
        status = invalid_state("CMQ wait requires an ACTIVE engine");
        engine_lock.put(1);
        return;
      end
      fallback_outstanding = ticket_is_outstanding(ticket_snapshot);
      if (!fallback_outstanding && terminal_index(ticket_snapshot) < 0) begin
        status = invalid_argument("CMQ wait ticket is unknown or delivered");
        engine_lock.put(1);
        return;
      end
      if (prepared_binding == null ||
          !rdma_cmq_try_snapshot_identity_direct(
            prepared_binding.function_identity_snapshot(), frozen_identity
          )) begin
        status = invalid_state("CMQ wait Function snapshot failed");
        engine_lock.put(1);
        return;
      end
    end

    forever begin
      if (journal_located) begin
        // Re-read the exact retained row before every delivery/side effect.
        validation_status = locate_journal_item_by_ticket_locked(
          ticket_snapshot, current_batch, current_item, current_item_index
        );
        if (validation_status == null || !validation_status.ok() ||
            current_batch == null || current_item == null ||
            current_item_index != frozen_item_index ||
            current_batch.batch_key != frozen_batch.batch_key ||
            current_batch.engine_incarnation != frozen_batch.engine_incarnation ||
            current_batch.function_identity == null ||
            !current_batch.function_identity.same_incarnation(frozen_identity)) begin
          // A reset may have won between iterations.  Only a retained reset
          // completion is allowed to cross that boundary.
          if (validation_status != null && validation_status.ok() &&
              current_item != null &&
              current_item.state == RDMA_CMQ_SUBMISSION_RESET_QUARANTINED) begin
            snapshot_status = snapshot_retained_completion_locked(
              current_batch, current_item, detached_completion
            );
            if (snapshot_status != null && snapshot_status.ok()) begin
              completion = detached_completion;
              status = copy_submit_status_direct(
                detached_completion.status, "cmq_wait_reset_status"
              );
              engine_lock.put(1);
              return;
            end
          end
          status = invalid_state("CMQ wait retained authority changed");
          engine_lock.put(1);
          return;
        end
        frozen_batch = current_batch;
        frozen_item = current_item;
        if (current_item.completion != null &&
            current_item.completion_phase inside {
              RDMA_CMQ_COMPLETION_TERMINAL,
              RDMA_CMQ_COMPLETION_TIMEOUT,
              RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY,
              RDMA_CMQ_COMPLETION_RESET_CANCELLED
            }) begin
          snapshot_status = snapshot_retained_completion_locked(
            current_batch, current_item, detached_completion
          );
          if (snapshot_status == null || !snapshot_status.ok()) begin
            status = (snapshot_status == null) ? invalid_state(
              "CMQ wait retained completion snapshot returned null status"
            ) : snapshot_status;
            engine_lock.put(1);
            return;
          end
          fifo_index = terminal_index(ticket_snapshot);
          if (fifo_index >= 0)
            terminal_fifo.delete(fifo_index);
          completion = detached_completion;
          status = copy_submit_status_direct(
            detached_completion.status, "cmq_wait_completion_status"
          );
          if (status == null)
            status = invalid_state("CMQ wait completion status snapshot failed");
          engine_lock.put(1);
          return;
        end
        if (current_item.state == RDMA_CMQ_SUBMISSION_RESET_QUARANTINED) begin
          status = invalid_state("CMQ reset item has no retained completion");
          engine_lock.put(1);
          return;
        end
        if (!(current_item.state inside {
              RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
              RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
            }) || current_item.completion_phase !=
              RDMA_CMQ_COMPLETION_PENDING) begin
          status = invalid_state("CMQ wait pending lifecycle is invalid");
          engine_lock.put(1);
          return;
        end
        // Revalidate current runtime Function identity and incarnation before
        // invoking expiry/poll, which may read CQ backing or mutate journal.
        current_identity = null;
        if (engine_state != RDMA_CMQ_ENGINE_ACTIVE ||
            engine_incarnation != frozen_batch.engine_incarnation ||
            prepared_binding == null ||
            !rdma_cmq_try_snapshot_identity_direct(
              prepared_binding.function_identity_snapshot(), current_identity
            ) || current_identity == null ||
            !current_identity.same_incarnation(frozen_identity) ||
            !ticket_has_engine_authority(ticket_snapshot)) begin
          status = invalid_state("CMQ wait current runtime authority changed");
          engine_lock.put(1);
          return;
        end
      end
      else if (terminal_index(ticket_snapshot) >= 0) begin
        // Legacy FIFO fallback has no retained graph; consume only its exact
        // row and preserve the historical one-shot delivery semantics.
        fifo_index = terminal_index(ticket_snapshot);
        completion = terminal_fifo[fifo_index];
        terminal_fifo.delete(fifo_index);
        if (completion == null || completion.status == null) begin
          completion = null;
          status = invalid_state("CMQ wait legacy completion is incomplete");
        end
        else
          status = copy_submit_status_direct(
            completion.status, "cmq_wait_legacy_status"
          );
        engine_lock.put(1);
        return;
      end

      expiry_status = expire_locked();
      if (expiry_status == null || !expiry_status.ok()) begin
        status = (expiry_status == null) ? invalid_state(
          "CMQ wait expiry helper returned null status"
        ) : expiry_status;
        engine_lock.put(1);
        return;
      end
      poll_status = rdma_status::success();
      poll_locked(poll_status);
      if (poll_status == null || !poll_status.ok()) begin
        status = (poll_status == null) ? invalid_state(
          "CMQ wait poll helper returned null status"
        ) : poll_status;
        engine_lock.put(1);
        return;
      end

      // The next loop rereads journal/FIFO.  A deadline transition is thus
      // delivered as the retained non-null RDMA_SC_TIMEOUT completion.
      if ($time >= ticket_snapshot.absolute_deadline &&
          journal_located) begin
        validation_status = locate_journal_item_by_ticket_locked(
          ticket_snapshot, current_batch, current_item, current_item_index
        );
        if (validation_status != null && validation_status.ok() &&
            current_item != null && current_item.completion != null &&
            current_item.completion_phase == RDMA_CMQ_COMPLETION_TIMEOUT)
          continue;
        if (current_item != null &&
            current_item.state inside {
              RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
              RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
            }) begin
          // expire_locked should have transitioned an owned slot; if it did
          // not, fail closed rather than manufacturing a status without evidence.
          status = invalid_state("CMQ wait deadline transition is missing");
          engine_lock.put(1);
          return;
        end
      end

      if (journal_located && !ticket_is_outstanding(ticket_snapshot) &&
          terminal_index(ticket_snapshot) < 0) begin
        // A reset/terminal transition will be observed at the top of the next
        // iteration; absent both evidence and runtime authority is delivery loss.
        validation_status = locate_journal_item_by_ticket_locked(
          ticket_snapshot, current_batch, current_item, current_item_index
        );
        if (validation_status == null || !validation_status.ok() ||
            current_item == null || current_item.completion == null) begin
          status = invalid_argument("CMQ wait ticket is unknown or delivered");
          engine_lock.put(1);
          return;
        end
      end
      if ($isunknown(ticket_snapshot.absolute_deadline) ||
          ticket_snapshot.absolute_deadline == 0) begin
        status = invalid_argument("CMQ wait ticket deadline is invalid");
        engine_lock.put(1);
        return;
      end
      if ($time >= ticket_snapshot.absolute_deadline) begin
        // Top-of-loop expiry should have installed a completion.  Keep the
        // invariant explicit and never return INVALID_STATE as a timeout.
        status = invalid_state("CMQ wait deadline transition is unavailable");
        engine_lock.put(1);
        return;
      end
      remaining = ticket_snapshot.absolute_deadline - $time;
      wait_time = (remaining < 1ns) ? remaining : 1ns;
      engine_lock.put(1);
      #(wait_time);
      engine_lock.get(1);
      if (journal_located) begin
        validation_status = locate_journal_item_by_ticket_locked(
          ticket_snapshot, current_batch, current_item, current_item_index
        );
        if (validation_status == null || !validation_status.ok() ||
            current_batch == null || current_item == null ||
            current_item_index != frozen_item_index ||
            current_batch.batch_key != frozen_batch.batch_key ||
            current_batch.engine_incarnation != frozen_batch.engine_incarnation ||
            current_batch.function_identity == null ||
            !current_batch.function_identity.same_incarnation(frozen_identity)) begin
          status = invalid_state("CMQ wait retained authority changed after unlock");
          engine_lock.put(1);
          return;
        end
        // Revalidation before the next loop's CQ access is intentional; the
        // loop will additionally check current ACTIVE runtime identity.
      end
      else if (engine_state != RDMA_CMQ_ENGINE_ACTIVE) begin
        status = invalid_state("CMQ engine changed state during wait");
        engine_lock.put(1);
        return;
      end
    end
  endtask

  // 功能：在 rdma_cmq_engine 中，reconcile_ticket 以 retained journal 的单项
  //   生命周期为唯一观察依据，按状态返回未发布 operation status 或终态 completion。
  // 输入/输出及副作用：ticket 为 caller 的只读输入；terminal_known、completion、
  //   status 为 detached 输出。只有当前 ACTIVE incarnation 的 PENDING 项会调用
  //   一次 expire_locked()/poll_locked()；终态、未发布和复位证据只读 journal。
  // 失败/边界：坏 ticket、journal index 歧义、STAGED/PENDING_EFFECT、旧 pending
  //   缺少当前 runtime authority 或 retained graph 不完整时 fail closed；不删除
  //   FIFO/journal completion、不重试发布、不敲 doorbell，重复终态观察保持幂等。
  task reconcile_ticket(
    rdma_cmq_ticket ticket,
    output bit terminal_known,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    rdma_status validation_status;
    rdma_status helper_status;
    rdma_status operation_status;
    rdma_status snapshot_status;
    rdma_cmq_ticket ticket_snapshot;
    rdma_cmq_batch_submission_record batch_record;
    rdma_cmq_batch_submission_item_record journal_item;
    rdma_cmq_completion detached_completion;
    rdma_cmq_nonfatal_snapshot_context snapshot_context;
    rdma_function_identity current_identity;
    string failure_reason;
    int unsigned journal_item_index;
    bit pending_active;
    bit terminal_row;

    terminal_known = 1'b0;
    completion = null;
    status = invalid_state("CMQ ticket reconcile did not complete");
    engine_lock.get(1);
    if (ticket == null) begin
      status = invalid_argument("CMQ reconcile ticket is null");
      engine_lock.put(1);
      return;
    end
    if (!rdma_cmq_ticket_shape_valid(ticket)) begin
      status = invalid_argument("CMQ reconcile ticket is invalid");
      engine_lock.put(1);
      return;
    end

    // 用 direct nonfatal seam 冻结 caller ticket；reconcile 不应因当前
    // runtime 已 reset，或因 delivery FIFO 已被其他消费者清空，而改变查询值。
    snapshot_context = new();
    if (!snapshot_context.try_snapshot_optional_ticket(
          ticket, ticket_snapshot, failure_reason
        ) || ticket_snapshot == null) begin
      status = invalid_argument(
        {"CMQ reconcile ticket snapshot failed: ", failure_reason}
      );
      engine_lock.put(1);
      return;
    end

    // 先查稳定 ticket index，再决定是否需要当前 runtime authority；这是
    // old reset/timeout/late ticket 能跨 reprepare 被观察的关键顺序。
    validation_status = locate_journal_item_by_ticket_locked(
      ticket_snapshot, batch_record, journal_item,
      journal_item_index
    );
    if (validation_status == null || !validation_status.ok()) begin
      status = (validation_status == null) ? invalid_state(
        "CMQ reconcile journal locator returned null status"
      ) : validation_status;
      engine_lock.put(1);
      return;
    end

    pending_active =
      journal_item.state inside {
        RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
        RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
      } && journal_item.completion_phase == RDMA_CMQ_COMPLETION_PENDING &&
      journal_item.completion == null;

    if (pending_active) begin
      // 只有同一 ACTIVE engine incarnation 的真实 published item 才能
      // 触发一次 expire/poll；unarmed fenced row 与旧 incarnation 直接失败。
      current_identity = null;
      if (engine_state != RDMA_CMQ_ENGINE_ACTIVE ||
          prepared_binding == null || cmq_snapshot == null ||
          cmq_snapshot.handle == null ||
          batch_record.engine_incarnation != engine_incarnation ||
          batch_record.function_identity == null ||
          !rdma_cmq_try_snapshot_identity_direct(
            prepared_binding.function_identity_snapshot(), current_identity
          ) || current_identity == null ||
          !batch_record.function_identity.same_incarnation(current_identity) ||
          !same_handle(cmq_snapshot.handle, batch_record.cmq_h) ||
          !ticket_has_engine_authority(ticket_snapshot)) begin
        status = invalid_state(
          "CMQ reconcile pending ticket lacks current runtime authority"
        );
        engine_lock.put(1);
        return;
      end

      helper_status = expire_locked();
      if (helper_status == null || !helper_status.ok()) begin
        status = (helper_status == null) ? invalid_state(
          "CMQ reconcile expiry returned null status"
        ) : helper_status;
        engine_lock.put(1);
        return;
      end
      helper_status = rdma_status::success();
      poll_locked(helper_status);
      if (helper_status == null || !helper_status.ok()) begin
        status = (helper_status == null) ? invalid_state(
          "CMQ reconcile poll returned null status"
        ) : helper_status;
        engine_lock.put(1);
        return;
      end

      // expire/poll 可能同时推进其他 slot；只重新读取原 ticket 对应的
      // retained item，绝不从 FIFO 顺序或 slot index 猜测结果。
      validation_status = locate_journal_item_by_ticket_locked(
        ticket_snapshot, batch_record, journal_item,
        journal_item_index
      );
      if (validation_status == null || !validation_status.ok()) begin
        status = (validation_status == null) ? invalid_state(
          "CMQ reconcile journal reread returned null status"
        ) : validation_status;
        engine_lock.put(1);
        return;
      end
      pending_active =
        journal_item.state inside {
          RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
          RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
        } && journal_item.completion_phase == RDMA_CMQ_COMPLETION_PENDING &&
        journal_item.completion == null;
    end

    // 下面的分类完全由 exact item state/phase 驱动；completion 是否存在
    // 只能作为该状态的结构校验，不能反向决定 lifecycle phase。
    if (journal_item == null || batch_record == null) begin
      status = invalid_state("CMQ reconcile retained item is missing");
      engine_lock.put(1);
      return;
    end
    if (journal_item.state inside {
          RDMA_CMQ_SUBMISSION_STAGED,
          RDMA_CMQ_SUBMISSION_PENDING_EFFECT
        }) begin
      status = invalid_state(
        "CMQ reconcile item is staged or has a pending external effect"
      );
      engine_lock.put(1);
      return;
    end

    if (journal_item.state == RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED) begin
      if (journal_item.completion_phase != RDMA_CMQ_COMPLETION_NONE ||
          journal_item.completion != null) begin
        status = invalid_state(
          "CMQ unarmed reconcile item has terminal evidence"
        );
        engine_lock.put(1);
        return;
      end
      snapshot_status = snapshot_retained_operation_status_locked(
        journal_item, operation_status
      );
      if (snapshot_status == null || !snapshot_status.ok() ||
          operation_status == null) begin
        status = (snapshot_status == null) ? invalid_state(
          "CMQ unarmed reconcile status snapshot returned null"
        ) : snapshot_status;
        engine_lock.put(1);
        return;
      end
      terminal_known = 1'b0;
      completion = null;
      status = operation_status;
      engine_lock.put(1);
      return;
    end

    if (pending_active) begin
      if (journal_item.completion_phase != RDMA_CMQ_COMPLETION_PENDING ||
          journal_item.completion != null ||
          !(journal_item.state inside {
            RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
            RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
          })) begin
        status = invalid_state("CMQ reconcile pending item is malformed");
        engine_lock.put(1);
        return;
      end
      snapshot_status = snapshot_retained_operation_status_locked(
        journal_item, operation_status
      );
      if (snapshot_status == null || !snapshot_status.ok() ||
          operation_status == null) begin
        status = (snapshot_status == null) ? invalid_state(
          "CMQ pending reconcile status snapshot returned null"
        ) : snapshot_status;
        engine_lock.put(1);
        return;
      end
      terminal_known = 1'b0;
      completion = null;
      status = operation_status;
      engine_lock.put(1);
      return;
    end

    terminal_row = 1'b0;
    case (journal_item.state)
      RDMA_CMQ_SUBMISSION_COMPLETED:
        terminal_row = journal_item.completion_phase ==
                       RDMA_CMQ_COMPLETION_TERMINAL;
      RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED:
        terminal_row = journal_item.completion_phase ==
                       RDMA_CMQ_COMPLETION_TIMEOUT;
      RDMA_CMQ_SUBMISSION_LATE_COMPLETED:
        terminal_row = journal_item.completion_phase ==
                       RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY;
      RDMA_CMQ_SUBMISSION_RESET_QUARANTINED:
        terminal_row = journal_item.completion_phase ==
                       RDMA_CMQ_COMPLETION_RESET_CANCELLED;
      default:
        terminal_row = 1'b0;
    endcase
    if (!terminal_row || journal_item.completion == null) begin
      status = invalid_state("CMQ reconcile retained lifecycle is malformed");
      engine_lock.put(1);
      return;
    end

    snapshot_status = snapshot_retained_completion_locked(
      batch_record, journal_item, detached_completion
    );
    if (snapshot_status == null || !snapshot_status.ok() ||
        detached_completion == null || detached_completion.status == null) begin
      status = (snapshot_status == null) ? invalid_state(
        "CMQ reconcile retained completion snapshot returned null"
      ) : snapshot_status;
      engine_lock.put(1);
      return;
    end
    operation_status = copy_submit_status_direct(
      detached_completion.status, "cmq_reconcile_terminal_status"
    );
    if (operation_status == null) begin
      status = invalid_state("CMQ reconcile terminal status snapshot failed");
      engine_lock.put(1);
      return;
    end
    terminal_known = 1'b1;
    completion = detached_completion;
    status = operation_status;
    engine_lock.put(1);
  endtask

  // 功能：在 rdma_cmq_engine 中，cancel_generation 根据当前证据转换事务或恢复状态，并保持重试、复位和所有权边界一致。
  // 输入/输出及副作用：generation（输入）、completions（输出）、status（输出）；cancel_generation 驱动下游事务，并写入 completions、status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：cancel_generation 失败或超时通过 completions、status 明确发布；该路径不隐式重试，也不转移未声明资源。
  task cancel_generation(
    int unsigned generation,
    output rdma_cmq_completion completions[$],
    output rdma_status status
  );
    completions.delete();
    status = invalid_state("CMQ generation cancel did not complete");
    engine_lock.get(1);
    if (!(engine_state inside {
          RDMA_CMQ_ENGINE_PREPARED,
          RDMA_CMQ_ENGINE_ACTIVE,
          RDMA_CMQ_ENGINE_QUIESCED
        })) begin
      status = invalid_state("CMQ engine state cannot be cancelled");
      engine_lock.put(1);
      return;
    end
    status = cancel_generation_locked(generation, 1'b0);
    if (status != null && status.ok()) begin
      while (terminal_fifo.size() != 0)
        completions.push_back(terminal_fifo.pop_front());
    end
    if (status == null)
      status = invalid_state("CMQ generation cancel returned null status");
    engine_lock.put(1);
  endtask

  // 功能：判断 retained journal item 是否必须在 reset 中转换为
  // RESET_QUARANTINED，并保留一份 cancellation completion。
  // 输入/输出及副作用：state 为只读生命周期状态；函数只返回分类结果，不修改 item、slot 或 proof。
  // 失败/边界：STAGED/PENDING_EFFECT 也必须有完整 concrete effect 才能进入 reset staging；已完成/已隔离状态不重复取消。
  protected function bit reset_item_requires_quarantine(
    input rdma_cmq_submission_state_e state
  );
    return state inside {
      RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED,
      RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
      RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED,
      RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED,
      RDMA_CMQ_SUBMISSION_RESET_QUARANTINED
    };
  endfunction

  // 功能：在 observed reset staging 前以只读方式核对当前 runtime 的
  //   slot/entry/command/token/cursor 图与 retained journal 的 exact locator，
  //   让损坏的 POISONED/QUIESCED authority 在任何 release I/O 前 fail closed。
  // 输入/输出及副作用：无外部输出；函数只读 engine ledger、当前 binding/CMQ
  //   snapshot 与 journal，返回成功或具体 INVALID_STATE，不 poison、不清 FIFO、
  //   不修复任何容器。
  // 失败/边界：counter 逆序/越深、CQ 游标越界、slot incarnation/locator/ticket
  //   漂移、entry/command/token membership 不精确、journal phase 不匹配或出现
  //   stray token/registry row 时拒绝；空 runtime ledger 合法。
  protected function rdma_status reset_runtime_ledger_status_locked();
    longint unsigned used;
    int unsigned slot_count;
    int unsigned published_slot_count;
    int unsigned quarantined_slot_count;
    int unsigned token_count;

    if (publish_seq < retire_seq)
      return invalid_state("CMQ reset runtime publish counter precedes retire");
    used = publish_seq - retire_seq;
    if (used > CMQ_DEPTH)
      return invalid_state("CMQ reset runtime ring occupancy exceeds depth");
    if (cq_consume_seq < retire_seq || cq_consume_seq > publish_seq)
      return invalid_state("CMQ reset runtime completion counters are inconsistent");

    slot_count = 0;
    published_slot_count = 0;
    quarantined_slot_count = 0;
    token_count = 0;
    foreach (slots[i]) begin
      rdma_cmq_slot_record record;
      rdma_cmq_batch_submission_record batch_record;
      rdma_cmq_batch_submission_item_record journal_item;
      string hardware_key;
      string software_key;

      if (token_in_use[i])
        token_count++;
      record = slots[i];
      if (record == null)
        continue;
      slot_count++;
      if ($isunknown(record.slot_sequence) ||
          $isunknown(record.sq_index) ||
          $isunknown(record.sq_wrap) ||
          $isunknown(record.state) ||
          $isunknown(record.command_token) ||
          record.sq_index != i || record.sq_index >= CMQ_DEPTH ||
          record.sq_index != (record.slot_sequence % CMQ_DEPTH) ||
          record.sq_wrap != ((record.slot_sequence / CMQ_DEPTH) % 2) ||
          record.ticket == null || record.expected == null ||
          record.batch_key.len() == 0 ||
          record.journal_item_index >= CMQ_DEPTH ||
          prepared_binding == null || cmq_snapshot == null ||
          cmq_snapshot.handle == null)
        return invalid_state("CMQ reset runtime slot authority is incomplete");
      if (!rdma_cmq_ticket_shape_valid(record.ticket) ||
          record.ticket.sq_index != record.sq_index ||
          record.ticket.slot_sequence != record.slot_sequence ||
          record.ticket.sq_wrap != record.sq_wrap ||
          record.ticket.command_id[4:0] != record.command_token ||
          record.ticket.function_h.generation != prepared_binding.generation ||
          !prepared_binding.accepts(record.ticket.function_h) ||
          !same_handle(record.ticket.cmq_h, cmq_snapshot.handle))
        return invalid_state("CMQ reset runtime ticket authority is inconsistent");
      if (!submission_journal.exists(record.batch_key) ||
          submission_journal[record.batch_key] == null)
        return invalid_state("CMQ reset runtime journal locator is unknown");
      batch_record = submission_journal[record.batch_key];
      if (record.journal_item_index >= batch_record.items.size())
        return invalid_state("CMQ reset runtime journal item index is invalid");
      journal_item = batch_record.items[record.journal_item_index];
      if (journal_item == null || journal_item.ticket == null ||
          !same_ticket_value(record.ticket, journal_item.ticket) ||
          journal_item.slot_sequence != record.slot_sequence ||
          journal_item.slot_index != record.sq_index ||
          journal_item.slot_wrap != record.sq_wrap ||
          journal_item.command_token != record.command_token)
        return invalid_state("CMQ reset runtime slot/journal locator disagrees");

      hardware_key = entry_key(record.sq_index, record.sq_wrap);
      if (!entry_registry.exists(hardware_key) ||
          entry_registry[hardware_key] != record)
        return invalid_state("CMQ reset runtime entry registry is inconsistent");
      software_key = command_key(record.ticket);
      case (record.state)
        CMQ_SLOT_PUBLISHED: begin
          published_slot_count++;
          if (journal_item.completion_phase != RDMA_CMQ_COMPLETION_PENDING ||
              journal_item.completion != null ||
              !command_registry.exists(software_key) ||
              command_registry[software_key] != record ||
              record.command_token >= CMQ_DEPTH ||
              !token_in_use[record.command_token] ||
              token_incarnation[record.command_token] !=
                record.ticket.command_id[63:5])
            return invalid_state("CMQ reset runtime published membership is inconsistent");
        end
        CMQ_SLOT_TIMED_OUT_QUARANTINED: begin
          quarantined_slot_count++;
          if (journal_item.completion_phase != RDMA_CMQ_COMPLETION_TIMEOUT ||
              journal_item.completion == null ||
              command_registry.exists(software_key) ||
              record.command_token >= CMQ_DEPTH ||
              !token_in_use[record.command_token] ||
              token_incarnation[record.command_token] !=
                record.ticket.command_id[63:5])
            return invalid_state("CMQ reset runtime timeout membership is inconsistent");
        end
        CMQ_SLOT_RESET_CANCELLED: begin
          quarantined_slot_count++;
          if (journal_item.completion_phase !=
                RDMA_CMQ_COMPLETION_RESET_CANCELLED ||
              journal_item.completion == null ||
              command_registry.exists(software_key) ||
              record.command_token >= CMQ_DEPTH ||
              !token_in_use[record.command_token] ||
              token_incarnation[record.command_token] !=
                record.ticket.command_id[63:5])
            return invalid_state("CMQ reset runtime cancellation membership is inconsistent");
        end
        CMQ_SLOT_COMPLETED: begin
          if (journal_item.completion_phase != RDMA_CMQ_COMPLETION_TERMINAL ||
              journal_item.completion == null ||
              command_registry.exists(software_key) ||
              (record.command_token < CMQ_DEPTH &&
               token_in_use[record.command_token]))
            return invalid_state("CMQ reset runtime completed membership is inconsistent");
        end
        CMQ_SLOT_LATE_COMPLETED: begin
          if (journal_item.completion_phase !=
                RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY ||
              journal_item.completion == null ||
              command_registry.exists(software_key) ||
              (record.command_token < CMQ_DEPTH &&
               token_in_use[record.command_token]))
            return invalid_state("CMQ reset runtime late membership is inconsistent");
        end
        default:
          return invalid_state("CMQ reset runtime slot state is unsupported");
      endcase
    end
    if (slot_count != used || entry_registry.num() != slot_count ||
        command_registry.num() != published_slot_count ||
        token_count != published_slot_count + quarantined_slot_count)
      return invalid_state("CMQ reset runtime ledger membership is inconsistent");
    return rdma_status::success();
  endfunction

  // 功能：在任何 engine-owned 状态变化前预建 reset candidate；它收集旧
  //   Function/backing、逐项取消 completion、batch proof 和 detached 返回图。
  // 输入/输出及副作用：candidate 为输出；只读当前 journal/profile/runtime，所有
  //   new/clone/摘要计算均写入本地 candidate，不改 map、FIFO、counter、fence 或 state。
  // 失败/边界：缺 backing/Function、journal invariant/digest/owner 损坏、proof tuple
  //   不完整、ID 预估溢出或任一 snapshot/cancellation 构造失败均返回错误且输出 null。
  protected function rdma_status stage_reset_candidate_locked(
    output rdma_cmq_reset_candidate candidate
  );
    rdma_cmq_reset_candidate staged_candidate;
    rdma_function_identity isolated_identity;
    rdma_status status;
    longint unsigned next_proof_id;
    longint unsigned max_id;
    string affected_batch_keys[$];

    candidate = null;
    max_id = 64'hffff_ffff_ffff_ffff;
    if (!(engine_state inside {
          RDMA_CMQ_ENGINE_PREPARED,
          RDMA_CMQ_ENGINE_ACTIVE,
          RDMA_CMQ_ENGINE_QUIESCED,
          RDMA_CMQ_ENGINE_POISONED
        }))
      return invalid_state("CMQ reset candidate engine state is not resettable");
    if (prepared_binding == null || backing_mapping == null || host_mem == null)
      return invalid_state("CMQ reset candidate release authority is missing");
    if (!rdma_cmq_try_snapshot_identity_direct(
          prepared_binding.function_identity_snapshot(), isolated_identity
        ))
      return invalid_state("CMQ reset candidate Function snapshot failed");
    staged_candidate = new("cmq_reset_candidate");
    if (staged_candidate == null)
      return invalid_state("CMQ reset candidate construction failed");
    staged_candidate.isolated_identity = isolated_identity;
    // 释放必须使用 adapter 产生的 opaque authority 快照，而不是把
    // engine 当前可变 public mapping 句柄直接带出锁外。
    status = backing_mapping.snapshot_release_authority(
      staged_candidate.backing_release_authority
    );
    if (status == null || !status.ok() ||
        staged_candidate.backing_release_authority == null)
      return (status == null) ? invalid_state(
        "CMQ reset backing authority snapshot returned null"
      ) : status;
    status = host_mem.validate_failure_atomic_release(
      staged_candidate.backing_release_authority
    );
    if (status == null || !status.ok())
      return (status == null) ? invalid_state(
        "CMQ reset backing authority equivalence returned null"
      ) : status;
    // A poisoned runtime is still resettable only when its local authority is
    // internally self-consistent.  This audit is deliberately read-only so a
    // malformed slot/token/registry cannot be "recovered" by clearing it
    // before the backing release transaction has succeeded.
    status = reset_runtime_ledger_status_locked();
    if (status == null || !status.ok())
      return (status == null) ? invalid_state(
        "CMQ reset runtime ledger audit returned null"
      ) : status;
    staged_candidate.runtime_backing_mapping = backing_mapping;
    staged_candidate.backing_release_service = host_mem;
    staged_candidate.runtime_host_mem = host_mem;
    staged_candidate.backing_release_opaque = backing_release_opaque;
    staged_candidate.runtime_state = engine_state;
    staged_candidate.engine_incarnation = engine_incarnation;
    staged_candidate.runtime_publish_seq = publish_seq;
    staged_candidate.runtime_retire_seq = retire_seq;
    staged_candidate.runtime_cq_consume_seq = cq_consume_seq;
    staged_candidate.runtime_batch_id_counter = batch_id_counter;
    staged_candidate.runtime_attempt_id_counter = attempt_id_counter;
    staged_candidate.runtime_reset_proof_id_counter = reset_proof_id_counter;
    staged_candidate.runtime_journal_count = submission_journal.num();
    staged_candidate.runtime_ticket_index_count = journal_batch_by_ticket.num();
    staged_candidate.runtime_preallocation_count =
      preallocated_publish_batches.num();
    staged_candidate.runtime_observer_count = arm_observers.num();
    staged_candidate.runtime_command_count = command_registry.num();
    staged_candidate.runtime_entry_count = entry_registry.num();
    staged_candidate.runtime_terminal_fifo_count = terminal_fifo.size();
    staged_candidate.runtime_diagnostic_fifo_count = diagnostic_fifo.size();
    staged_candidate.runtime_late_fifo_count = late_final_fifo.size();
    foreach (slots[slot_i]) begin
      if (slots[slot_i] != null)
        staged_candidate.runtime_slot_count++;
      if (token_in_use[slot_i])
        staged_candidate.runtime_token_count++;
    end
    staged_candidate.runtime_fenced_batch_key = fenced_batch_key;
    staged_candidate.runtime_fence_reason = submission_fence_reason;

    // 先只读扫描 retained rows，确定 N；counter 只有 commit 才能推进。
    foreach (submission_journal[batch_key]) begin
      rdma_cmq_batch_submission_record row;
      rdma_cmq_hw_profile retained_profile;
      bit affected;

      row = submission_journal[batch_key];
      if (row == null || row.engine_incarnation != engine_incarnation)
        continue;
      status = submission_journal_invariant_locked(batch_key);
      if (status == null || !status.ok())
        return (status == null) ? invalid_state(
          "CMQ reset candidate journal invariant returned null"
        ) : status;
      retained_profile = journal_profile_by_batch[batch_key];
      if (retained_profile == null)
        return invalid_state("CMQ reset candidate retained profile is missing");
      status = validate_submission_record_locked(row, retained_profile, 1'b0);
      if (status == null || !status.ok())
        return (status == null) ? invalid_state(
          "CMQ reset candidate retained record validation returned null"
        ) : status;
      affected = 1'b0;
      foreach (row.items[i]) begin
        if (row.items[i] == null)
          return invalid_state("CMQ reset candidate journal item is null");
        if (row.items[i].state inside {
              RDMA_CMQ_SUBMISSION_STAGED,
              RDMA_CMQ_SUBMISSION_PENDING_EFFECT
            })
          return invalid_state(
            "CMQ reset candidate contains an unobserved external effect"
          );
        if (row.items[i].state == RDMA_CMQ_SUBMISSION_RESET_QUARANTINED &&
            row.items[i].reset_isolation_confirmed)
          continue;
        if (reset_item_requires_quarantine(row.items[i].state)) begin
          affected = 1'b1;
        end
      end
      if (affected)
        affected_batch_keys.push_back(batch_key);
    end
    if (affected_batch_keys.size() > (max_id - reset_proof_id_counter))
      return journal_status(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "CMQ reset proof IDs would overflow"
      );

    // Existing delivery FIFO rows are copied before reset clears delivery order.
    foreach (terminal_fifo[fifo_i]) begin
      rdma_cmq_completion detached;
      rdma_cmq_nonfatal_snapshot_context context;
      rdma_cmq_hw_profile fifo_profile;

      if (terminal_fifo[fifo_i] == null || terminal_fifo[fifo_i].ticket == null)
        return invalid_state("CMQ reset terminal FIFO contains an incomplete row");
      fifo_profile = profile;
      if (journal_batch_by_ticket.exists(command_key(
            terminal_fifo[fifo_i].ticket
          ))) begin
        string fifo_batch_key;
        fifo_batch_key = journal_batch_by_ticket[command_key(
          terminal_fifo[fifo_i].ticket
        )];
        if (journal_profile_by_batch.exists(fifo_batch_key))
          fifo_profile = journal_profile_by_batch[fifo_batch_key];
      end
      if (fifo_profile == null)
        return invalid_state("CMQ reset FIFO retained profile is missing");
      context = new();
      status = snapshot_completion_with_profile_locked(
        terminal_fifo[fifo_i], context, fifo_profile, detached
      );
      if (status == null || !status.ok() || detached == null)
        return (status == null) ? invalid_state(
          "CMQ reset FIFO completion snapshot returned null"
        ) : status;
      staged_candidate.returned_completions.push_back(detached);
    end

    next_proof_id = reset_proof_id_counter;
    foreach (affected_batch_keys[b]) begin
      rdma_cmq_batch_submission_record row;
      rdma_cmq_hw_profile retained_profile;
      rdma_cmq_reset_batch_candidate batch_candidate;
      rdma_cmq_reset_isolation_proof proof;
      rdma_cmq_reset_isolation_proof proof_snapshot;
      rdma_function_identity proof_identity;
      rdma_cmq_submission_state_e reduced_state;
      rdma_cmq_batch_submission_item_record reducer_items[$];
      longint unsigned proof_id;
      string proof_key;
      string failure_reason;

      next_proof_id++;
      proof_id = next_proof_id;
      row = submission_journal[affected_batch_keys[b]];
      retained_profile = journal_profile_by_batch[affected_batch_keys[b]];
      if (row == null || retained_profile == null)
        return invalid_state("CMQ reset candidate batch row/profile is missing");
      if (!rdma_cmq_try_snapshot_identity_direct(
            row.function_identity, proof_identity
          ))
        return invalid_state("CMQ reset candidate proof identity snapshot failed");
      proof_key = $sformatf("%s|proof=%016h", row.batch_key, proof_id);
      proof = new($sformatf("cmq_reset_journal_proof_%0d", b));
      if (proof == null)
        return invalid_state("CMQ reset proof construction failed");
      proof.proof_key = proof_key;
      proof.proof_id = proof_id;
      proof.batch_key = row.batch_key;
      proof.batch_id = row.batch_id;
      proof.attempt_id = row.attempt_id;
      proof.engine_instance_id = row.engine_instance_id;
      proof.engine_incarnation = row.engine_incarnation;
      proof.isolated_identity = proof_identity;
      proof.replacement_identity = null;
      proof.batch_digest = row.batch_digest;
      proof.state = RDMA_CMQ_RESET_PROOF_AWAITING_REBIND;
      proof.backing_release_confirmed = 1'b1;
      foreach (row.items[i]) begin
        rdma_cmq_recovery_owner owner_snapshot;

        // The proof tuple names only items isolated by this reset.  Terminal
        // COMPLETED/LATE rows remain retained evidence but are not new
        // quarantine obligations and therefore are intentionally omitted.
        if (row.items[i] == null)
          return invalid_state("CMQ reset proof journal item is null");
        if (row.items[i].state == RDMA_CMQ_SUBMISSION_RESET_QUARANTINED &&
            row.items[i].reset_isolation_confirmed)
          continue;
        if (!reset_item_requires_quarantine(row.items[i].state))
          continue;

        if (row.items[i].recovery_owner == null)
          return invalid_state("CMQ reset proof recovery owner is missing");
        owner_snapshot = make_recovery_owner_locked(
          $sformatf("cmq_reset_proof_owner_%0d_%0d", b, i),
          row.items[i].recovery_owner
        );
        if (owner_snapshot == null)
          return invalid_state("CMQ reset proof owner snapshot failed");
        proof.isolated_request_indices.push_back(row.items[i].request_index);
        proof.isolated_image_digests.push_back(row.items[i].image_digest);
        proof.isolated_authority_digests.push_back(
          row.items[i].authority_digest
        );
        proof.isolated_recovery_owners.push_back(owner_snapshot);
      end
      status = rdma_cmq_compute_reset_proof_digest(
        proof.proof_key, proof.proof_id, proof.batch_key, proof.batch_id,
        proof.attempt_id, proof.engine_instance_id, proof.engine_incarnation,
        proof.isolated_identity, proof.batch_digest,
        proof.isolated_request_indices, proof.isolated_image_digests,
        proof.isolated_authority_digests, proof.isolated_recovery_owners,
        proof.proof_digest
      );
      if (status == null || !status.ok())
        return (status == null) ? invalid_state(
          "CMQ reset proof digest computation returned null"
        ) : status;
      status = rdma_cmq_compute_reset_proof_digest(
        proof.proof_key, proof.proof_id, proof.batch_key, proof.batch_id,
        proof.attempt_id, proof.engine_instance_id, proof.engine_incarnation,
        proof.isolated_identity, proof.batch_digest,
        proof.isolated_request_indices, proof.isolated_image_digests,
        proof.isolated_authority_digests, proof.isolated_recovery_owners,
        proof.proof_digest
      );
      if (status == null || !status.ok())
        return invalid_state("CMQ reset proof digest revalidation failed");
      status = snapshot_reset_proof_locked(proof, proof_snapshot);
      if (status == null || !status.ok() || proof_snapshot == null)
        return (status == null) ? invalid_state(
          "CMQ reset proof detached snapshot returned null"
        ) : status;

      batch_candidate = new($sformatf("cmq_reset_batch_%0d", b));
      if (batch_candidate == null)
        return invalid_state("CMQ reset batch candidate construction failed");
      batch_candidate.batch_key = row.batch_key;
      batch_candidate.quarantined_record = row;
      batch_candidate.journal_proof = proof;
      batch_candidate.returned_proof = proof_snapshot;

      foreach (row.items[i]) begin
        rdma_cmq_batch_submission_item_record reducer_item;
        bit needs_reset;

        reducer_item = new($sformatf("cmq_reset_reducer_%0d_%0d", b, i));
        if (reducer_item == null)
          return invalid_state("CMQ reset reducer candidate construction failed");
        needs_reset = reset_item_requires_quarantine(row.items[i].state) &&
                      !(
                        row.items[i].state ==
                          RDMA_CMQ_SUBMISSION_RESET_QUARANTINED &&
                        row.items[i].reset_isolation_confirmed
                      );
        reducer_item.state = needs_reset ?
          RDMA_CMQ_SUBMISSION_RESET_QUARANTINED : row.items[i].state;
        reducer_items.push_back(reducer_item);
      end
      status = rdma_cmq_reduce_batch_state(reducer_items, reduced_state);
      if (status == null || !status.ok())
        return (status == null) ? invalid_state(
          "CMQ reset batch reducer returned null"
        ) : status;
      batch_candidate.reduced_state = reduced_state;

      foreach (row.items[i]) begin
        rdma_cmq_batch_submission_item_record item;
        rdma_cmq_slot_record slot_candidate;
        rdma_cmq_completion cancellation;
        rdma_cmq_completion detached_cancellation;
        rdma_cmq_nonfatal_snapshot_context context;
        rdma_cmq_reset_item_candidate item_candidate;
        bit needs_reset;

        item = row.items[i];
        needs_reset = reset_item_requires_quarantine(item.state) &&
                      !(item.state == RDMA_CMQ_SUBMISSION_RESET_QUARANTINED &&
                        item.reset_isolation_confirmed);
        if (!needs_reset)
          continue;
        // A strict generation cancel may already have installed the retained
        // RESET_CANCELLED completion.  Observed reset still includes that
        // item in the proof tuple, but must not mint or return a duplicate.
        if (item.state == RDMA_CMQ_SUBMISSION_RESET_QUARANTINED)
          continue;
        if (item.completion != null || item.ticket == null ||
            item.command_token >= CMQ_DEPTH || item.entry_key.len() == 0)
          return invalid_state("CMQ reset item cancellation authority is incomplete");
        slot_candidate = new($sformatf("cmq_reset_slot_%0d_%0d", b, i));
        slot_candidate.slot_sequence = item.slot_sequence;
        slot_candidate.sq_index = item.slot_index;
        slot_candidate.sq_wrap = item.slot_wrap;
        slot_candidate.state = CMQ_SLOT_PUBLISHED;
        slot_candidate.ticket = item.ticket;
        slot_candidate.command_token = item.command_token;
        slot_candidate.batch_key = row.batch_key;
        slot_candidate.journal_item_index = i;
        status = make_cancel_completion(slot_candidate, cancellation);
        if (status == null || !status.ok() || cancellation == null)
          return (status == null) ? invalid_state(
            "CMQ reset cancellation completion returned null"
          ) : status;
        context = new();
        status = snapshot_completion_with_profile_locked(
          cancellation, context, retained_profile, detached_cancellation
        );
        if (status == null || !status.ok() || detached_cancellation == null)
          return (status == null) ? invalid_state(
            "CMQ reset cancellation snapshot returned null"
          ) : status;
        item_candidate = new($sformatf("cmq_reset_item_%0d_%0d", b, i));
        if (item_candidate == null)
          return invalid_state("CMQ reset item candidate construction failed");
        item_candidate.batch_key = row.batch_key;
        item_candidate.journal_item_index = i;
        item_candidate.request_index = item.request_index;
        item_candidate.slot_index = item.slot_index;
        item_candidate.command_key = command_key(item.ticket);
        item_candidate.entry_key = item.entry_key;
        item_candidate.cancellation_completion = cancellation;
        staged_candidate.items.push_back(item_candidate);
        staged_candidate.returned_completions.push_back(detached_cancellation);
      end
      staged_candidate.batches.push_back(batch_candidate);
    end
    candidate = staged_candidate;
    return journal_status(RDMA_SC_OK);
  endfunction

  // 功能：把已通过 backing release 的 reset candidate 无失败地写回 retained
  //   rows，并清空旧 runtime/fence/preallocation authority。
  // 输入/输出及副作用：candidate 为锁内完整输入；写入 journal item/batch、proof counter
  //   和既有 runtime 容器，不创建对象、不调用 adapter/scheduler，不返回 status。
  // 失败/边界：调用方必须先完成 stage、validator 与 release；若 candidate 缺少任一
  //   prebuilt handle 属于内部 invariant 破坏，函数只保守跳过该句柄而不做外部 I/O。
  protected function void commit_reset_candidate_locked(
    input rdma_cmq_reset_candidate candidate
  );
    if (candidate == null)
      return;
    foreach (candidate.batches[b]) begin
      rdma_cmq_reset_batch_candidate batch_candidate;

      batch_candidate = candidate.batches[b];
      if (batch_candidate == null || batch_candidate.quarantined_record == null)
        continue;
      foreach (candidate.items[i]) begin
        rdma_cmq_reset_item_candidate item_candidate;
        rdma_cmq_batch_submission_item_record item;

        item_candidate = candidate.items[i];
        if (item_candidate == null || item_candidate.batch_key !=
              batch_candidate.batch_key)
          continue;
        if (item_candidate.journal_item_index >=
              batch_candidate.quarantined_record.items.size())
          continue;
        item = batch_candidate.quarantined_record.items[
          item_candidate.journal_item_index
        ];
        if (item == null || item_candidate.cancellation_completion == null)
          continue;
        item.status = item_candidate.cancellation_completion.status;
        item.completion = item_candidate.cancellation_completion;
        item.state = RDMA_CMQ_SUBMISSION_RESET_QUARANTINED;
        item.completion_phase = RDMA_CMQ_COMPLETION_RESET_CANCELLED;
        item.reset_isolation_confirmed =
          item.recovery_owner != null &&
          item.recovery_owner.is_legacy_unmigrated();
        item.recovery_required = !item.reset_isolation_confirmed;
      end
      batch_candidate.quarantined_record.reset_isolation_proof =
        batch_candidate.journal_proof;
      batch_candidate.quarantined_record.state = batch_candidate.reduced_state;
      batch_candidate.quarantined_record.observer_armed = 1'b0;
    end
    reset_proof_id_counter += candidate.batches.size();
    arm_observers.delete();
    preallocated_publish_batches.delete();
    fenced_batch_key = "";
    submission_fence_reason = "";
    clear_configuration();
    engine_state = RDMA_CMQ_ENGINE_UNCONFIGURED;
  endfunction

  // 功能：执行 failure-atomic observed reset：先校验 release capability，再
  //   staging、backing release 和 allocation-free commit，最后发布 detached outputs。
  // 输入/输出及副作用：completions/proofs/status 为输出；成功释放旧 backing、隔离
  //   retained rows 并返回取消 completion/proof 快照，失败清空 outputs 且不改 engine。
  // 失败/边界：UNCONFIGURED 幂等成功；validator/release 返回 null 或 non-OK 时不
  //   调用 destructive cancel/clear，保留 runtime/journal/fence/counter/handles 原值。
  task reset_observed(
    output rdma_cmq_completion completions[$],
    output rdma_cmq_reset_isolation_proof proofs[],
    output rdma_status status
  );
    rdma_cmq_reset_candidate candidate;
    rdma_status release_status;
    rdma_status validation_status;
    bit candidate_runtime_unchanged;

    completions.delete();
    proofs = new[0];
    status = invalid_state("CMQ observed reset did not complete");
    engine_lock.get(1);
    if (engine_state == RDMA_CMQ_ENGINE_UNCONFIGURED) begin
      status = rdma_status::success();
      engine_lock.put(1);
      return;
    end
    if (!(engine_state inside {
          RDMA_CMQ_ENGINE_PREPARED,
          RDMA_CMQ_ENGINE_ACTIVE,
          RDMA_CMQ_ENGINE_QUIESCED,
          RDMA_CMQ_ENGINE_POISONED
        })) begin
      status = invalid_state("CMQ engine state cannot be observed-reset");
      engine_lock.put(1);
      return;
    end
    if (host_mem == null || backing_mapping == null) begin
      status = invalid_state("CMQ reset release authority is missing");
      engine_lock.put(1);
      return;
    end
    validation_status = host_mem.validate_failure_atomic_release(
      backing_mapping
    );
    if (validation_status == null || !validation_status.ok()) begin
      status = (validation_status == null) ? invalid_state(
        "CMQ reset release validator returned null status"
      ) : validation_status;
      engine_lock.put(1);
      return;
    end
    status = stage_reset_candidate_locked(candidate);
    if (status == null || !status.ok() || candidate == null) begin
      status = (status == null) ? invalid_state(
        "CMQ reset candidate staging returned null status"
      ) : status;
      engine_lock.put(1);
      return;
    end
    // Outputs and all detached graphs are sized before the external release;
    // release failure can therefore clear them without allocating or mutating rows.
    proofs = new[candidate.batches.size()];
    foreach (candidate.batches[i])
      proofs[i] = candidate.batches[i].returned_proof;
    foreach (candidate.returned_completions[i])
      completions.push_back(candidate.returned_completions[i]);

    // The adapter call is intentionally outside engine_lock.  The candidate
    // retains only detached release authority plus local witnesses; no
    // engine-owned graph is exposed to the adapter.
    engine_lock.put(1);
    if (candidate.backing_release_service == null)
      release_status = invalid_state(
        "CMQ reset candidate release service is missing"
      );
    else
      release_status = candidate.backing_release_service.release_opaque(
        candidate.backing_release_authority
      );

    engine_lock.get(1);
    if (release_status == null || !release_status.ok()) begin
      completions.delete();
      proofs.delete();
      status = (release_status == null) ? invalid_state(
        "CMQ reset release returned null status"
      ) : release_status;
      engine_lock.put(1);
      return;
    end

    // Any concurrent lifecycle change invalidates the staged graph.  In the
    // normal SV execution model release_opaque is non-blocking, but this
    // explicit CAS-style revalidation protects future adapters that yield.
    candidate_runtime_unchanged =
      engine_state == candidate.runtime_state &&
      backing_mapping === candidate.runtime_backing_mapping &&
      host_mem === candidate.runtime_host_mem &&
      backing_release_opaque == candidate.backing_release_opaque &&
      engine_incarnation == candidate.engine_incarnation &&
      publish_seq == candidate.runtime_publish_seq &&
      retire_seq == candidate.runtime_retire_seq &&
      cq_consume_seq == candidate.runtime_cq_consume_seq &&
      batch_id_counter == candidate.runtime_batch_id_counter &&
      attempt_id_counter == candidate.runtime_attempt_id_counter &&
      reset_proof_id_counter == candidate.runtime_reset_proof_id_counter &&
      submission_journal.num() == candidate.runtime_journal_count &&
      journal_batch_by_ticket.num() == candidate.runtime_ticket_index_count &&
      preallocated_publish_batches.num() ==
        candidate.runtime_preallocation_count &&
      arm_observers.num() == candidate.runtime_observer_count &&
      command_registry.num() == candidate.runtime_command_count &&
      entry_registry.num() == candidate.runtime_entry_count &&
      terminal_fifo.size() == candidate.runtime_terminal_fifo_count &&
      diagnostic_fifo.size() == candidate.runtime_diagnostic_fifo_count &&
      late_final_fifo.size() == candidate.runtime_late_fifo_count &&
      fenced_batch_key == candidate.runtime_fenced_batch_key &&
      submission_fence_reason == candidate.runtime_fence_reason;
    if (candidate_runtime_unchanged) begin
      int unsigned current_slot_count;
      int unsigned current_token_count;

      current_slot_count = 0;
      current_token_count = 0;
      foreach (slots[slot_i]) begin
        if (slots[slot_i] != null)
          current_slot_count++;
        if (token_in_use[slot_i])
          current_token_count++;
      end
      candidate_runtime_unchanged =
        current_slot_count == candidate.runtime_slot_count &&
        current_token_count == candidate.runtime_token_count;
    end
    if (candidate_runtime_unchanged) begin
      foreach (candidate.batches[b]) begin
        rdma_cmq_batch_submission_record retained_row;

        if (candidate.batches[b] == null ||
            candidate.batches[b].quarantined_record == null ||
            !submission_journal.exists(candidate.batches[b].batch_key)) begin
          candidate_runtime_unchanged = 1'b0;
          break;
        end
        retained_row = submission_journal[candidate.batches[b].batch_key];
        if (retained_row !== candidate.batches[b].quarantined_record ||
            retained_row.engine_incarnation != candidate.engine_incarnation ||
            retained_row.function_identity == null ||
            candidate.isolated_identity == null ||
            !retained_row.function_identity.same_incarnation(
              candidate.isolated_identity
            )) begin
          candidate_runtime_unchanged = 1'b0;
          break;
        end
      end
    end
    if (!candidate_runtime_unchanged) begin
      completions.delete();
      proofs.delete();
      status = invalid_state(
        "CMQ reset runtime authority changed during backing release"
      );
      engine_lock.put(1);
      return;
    end

    commit_reset_candidate_locked(candidate);
    status = rdma_status::success();
    engine_lock.put(1);
  endtask

  // 功能：按唯一 proof_key 扫描 retained journal，返回 proof 的 detached 快照，
  //   不建立第二张 proof authority table。
  // 输入/输出及副作用：proof_key 为只读输入；proof/status 为输出；只读 journal/profile
  //   并执行 uniqueness/full-value snapshot，不调用 adapter、scheduler 或 reset。
  // 失败/边界：空/未知 key 返回 INVALID_ARGUMENT；重复 key、损坏 batch/proof 或
  //   snapshot 失败返回 INVALID_STATE，且不发布 partial proof。
  task query_reset_isolation_proof(
    input string proof_key,
    output rdma_cmq_reset_isolation_proof proof,
    output rdma_status status
  );
    rdma_cmq_reset_isolation_proof source;
    int unsigned match_count;

    proof = null;
    status = invalid_state("CMQ reset proof query did not complete");
    if (proof_key.len() == 0) begin
      status = invalid_argument("CMQ reset proof key is empty");
      return;
    end
    engine_lock.get(1);
    match_count = 0;
    foreach (submission_journal[batch_key]) begin
      rdma_cmq_batch_submission_record row;
      rdma_cmq_hw_profile retained_profile;
      rdma_cmq_reset_isolation_proof row_proof_snapshot;
      rdma_status row_status;
      bit row_set_present;

      row = submission_journal[batch_key];
      if (row == null)
        continue;
      if (row.reset_isolation_proof != null &&
          row.reset_isolation_proof.proof_key == proof_key) begin
        row_status = journal_row_set_existence_locked(
          batch_key, row_set_present
        );
        if (row_status == null || !row_status.ok() || !row_set_present) begin
          status = (row_status == null) ? journal_status(
            RDMA_SC_INVALID_STATE,
            "CMQ reset proof journal row invariant returned null"
          ) : journal_status(RDMA_SC_INVALID_STATE, row_status.message);
          engine_lock.put(1);
          return;
        end
        if (!journal_profile_by_batch.exists(batch_key) ||
            journal_profile_by_batch[batch_key] == null) begin
          status = journal_status(
            RDMA_SC_INVALID_STATE,
            "CMQ reset proof retained profile is missing"
          );
          engine_lock.put(1);
          return;
        end
        retained_profile = journal_profile_by_batch[batch_key];
        row_status = validate_submission_record_locked(
          row, retained_profile, 1'b0
        );
        if (row_status == null || !row_status.ok()) begin
          status = (row_status == null) ? journal_status(
            RDMA_SC_INVALID_STATE,
            "CMQ reset proof retained journal validation returned null"
          ) : journal_status(RDMA_SC_INVALID_STATE, row_status.message);
          engine_lock.put(1);
          return;
        end
        row_status = snapshot_reset_proof_locked(
          row.reset_isolation_proof, row_proof_snapshot
        );
        if (row_status == null || !row_status.ok() ||
            row_proof_snapshot == null ||
            row_proof_snapshot.batch_key != row.batch_key ||
            row_proof_snapshot.batch_id != row.batch_id ||
            row_proof_snapshot.attempt_id != row.attempt_id ||
            row_proof_snapshot.engine_instance_id != row.engine_instance_id ||
            row_proof_snapshot.engine_incarnation != row.engine_incarnation ||
            row.function_identity == null ||
            row_proof_snapshot.isolated_identity == null ||
            !row_proof_snapshot.isolated_identity.same_incarnation(
              row.function_identity
            )) begin
          status = journal_status(
            RDMA_SC_INVALID_STATE,
            "CMQ reset proof retained value does not bind its journal row"
          );
          engine_lock.put(1);
          return;
        end
        match_count++;
        source = row.reset_isolation_proof;
      end
    end
    if (match_count == 0) begin
      status = invalid_argument("CMQ reset proof key is not retained");
      engine_lock.put(1);
      return;
    end
    if (match_count != 1) begin
      status = invalid_state("CMQ reset proof key is not unique");
      engine_lock.put(1);
      return;
    end
    status = snapshot_reset_proof_locked(source, proof);
    if (status == null)
      status = invalid_state("CMQ reset proof snapshot returned null status");
    engine_lock.put(1);
  endtask

  // 功能：在 rdma_cmq_engine 中把 legacy reset 调用转发到一次
  //   reset_observed()，保留历史 completion/status 投影并建立新生命周期边界。
  // 输入/输出及副作用：completions 与 status 为输出；内部临时
  //   ignored_proofs 接收 observed proof 输出后立即丢弃，调用方不取得 proof 所有权。
  // 失败/边界：validator、staging、backing release 或 commit 失败时传播
  //   reset_observed() 的非空 status；wrapper 不重复 cancel、release 或清理 runtime。
  task reset(
    output rdma_cmq_completion completions[$],
    output rdma_status status
  );
    rdma_cmq_reset_isolation_proof ignored_proofs[];

    // Legacy callers receive exactly the historical completion/status
    // projection.  All lifecycle, release and proof authority lives in the
    // single observed-reset transaction; this wrapper must not cancel twice.
    reset_observed(completions, ignored_proofs, status);
  endtask

  // 功能：在 rdma_cmq_engine 中，state 在锁保护下返回当前 engine/runtime 状态，不改变队列或恢复账本。
  // 输入/输出及副作用：无显式参数；state 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_cmq_engine_state_e，不取得调用方资源所有权。
  // 失败/边界：state 是只读访问器，返回 engine_state；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  function rdma_cmq_engine_state_e state();
    return engine_state;
  endfunction

  // 功能：在 rdma_cmq_engine 中，mapping_snapshot 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：无显式参数；mapping_snapshot 读取 对象字段：backing_mapping 并使用字段 cloned_object；函数返回 rdma_dma_mapping，不取得调用方资源所有权。
  // 失败/边界：mapping_snapshot 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CMQ mapping snapshot clone mismatch），不保留部分有效快照。
  function rdma_dma_mapping mapping_snapshot();
    uvm_object cloned_object;
    rdma_dma_mapping snapshot;

    if (backing_mapping == null)
      return null;
    cloned_object = backing_mapping.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object))
      `uvm_fatal("RDMA_COPY_TYPE", "CMQ mapping snapshot clone mismatch")
    return snapshot;
  endfunction

  // 功能：返回 rdma_cmq_engine 已发布的累计 sequence，供测试和诊断观察
  //   publication 进度，不重新计算或推进任何 ledger 状态。
  // 输入/输出及副作用：无参数；只读 publish_seq 并返回 longint unsigned，
  //   不写入 engine、队列、外部 adapter 或 scheduler。
  // 失败/边界：这是纯只读访问器，不具备失败分支；其值仅在 engine 生命周期
  //   内单调更新，调用方不得把它当作可写 cursor 或独立 authority。
  function longint unsigned published_count();
    return publish_seq;
  endfunction

  // 功能：返回 rdma_cmq_engine 已按有序规则退休的累计 sequence，供
  //   completion/ledger 诊断读取当前 retire 进度。
  // 输入/输出及副作用：无参数；只读 retire_seq 并返回 longint unsigned，
  //   不释放记录、不删除 registry，也不取得外部资源所有权。
  // 失败/边界：这是纯只读访问器，不具备失败分支；返回值只反映 engine
  //   已提交的 retire cursor，不能被调用方当作可复用 slot 的授权。
  function longint unsigned retired_count();
    return retire_seq;
  endfunction

  // 功能：cq_consumed_count 只读当前账本/队列状态并计算 longint unsigned 计数或可用容量，不推进任何事务游标。
  // 输入/输出及副作用：无显式参数；cq_consumed_count 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 longint unsigned，不取得调用方资源所有权。
  // 失败/边界：cq_consumed_count 是只读访问器，返回 cq_consume_seq；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  function longint unsigned cq_consumed_count();
    return cq_consume_seq;
  endfunction

  // 功能：outstanding_count 只读当前账本/队列状态并计算 int unsigned 计数或可用容量，不推进任何事务游标。
  // 输入/输出及副作用：无显式参数；outstanding_count 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：outstanding_count 是只读访问器，返回 command_registry.num()；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  function int unsigned outstanding_count();
    return command_registry.num();
  endfunction

  // 功能：quarantine_count 只读当前账本/队列状态并计算 int unsigned 计数或可用容量，不推进任何事务游标。
  // 输入/输出及副作用：无显式参数；quarantine_count 读取 对象字段：slots、state 并使用字段 count；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：quarantine_count 是只读访问器，返回 count；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  function int unsigned quarantine_count();
    int unsigned count;

    count = 0;
    foreach (slots[i]) begin
      if (slots[i] != null &&
          slots[i].state == CMQ_SLOT_TIMED_OUT_QUARANTINED)
        count++;
    end
    return count;
  endfunction

  // 功能：在 rdma_cmq_engine 中，last_poison_snapshot 只读查询当前运行时/测试账本，返回槽位、对象或恢复记录的快照而不推进事务。
  // 输入/输出及副作用：无显式参数；last_poison_snapshot 可能更新本对象明确拥有的状态；函数返回 rdma_cmq_diagnostic，不取得调用方资源所有权。
  // 失败/边界：last_poison_snapshot 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  function rdma_cmq_diagnostic last_poison_snapshot();
    rdma_status status;
    rdma_cmq_diagnostic snapshot;

    if (last_poison == null)
      return null;
    status = clone_diagnostic(last_poison, snapshot);
    if (status == null || !status.ok() || snapshot == null)
      return null;
    return snapshot;
  endfunction

  // 功能：在 rdma_cmq_engine 中，shutdown 停止接收新 CMQ 事务，清理本地队列和非拥有引用，并把 engine 切换到关闭状态。
  // 输入/输出及副作用：status（输出）；shutdown 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：shutdown 失败或超时通过 status 明确发布；该路径不隐式重试，也不转移未声明资源。
  task shutdown(output rdma_status status);
    rdma_status cancel_status;
    rdma_status release_status;

    status = invalid_state("CMQ shutdown did not complete");
    engine_lock.get(1);
    if (engine_state == RDMA_CMQ_ENGINE_UNCONFIGURED) begin
      clear_configuration();
      status = rdma_status::success();
      engine_lock.put(1);
      return;
    end
    if (!(engine_state inside {RDMA_CMQ_ENGINE_PREPARED,
                               RDMA_CMQ_ENGINE_ACTIVE,
                               RDMA_CMQ_ENGINE_QUIESCED,
                               RDMA_CMQ_ENGINE_POISONED})) begin
      status = invalid_state("CMQ engine state cannot be shut down");
      engine_lock.put(1);
      return;
    end
    if (engine_state != RDMA_CMQ_ENGINE_POISONED &&
        prepared_binding != null) begin
      // shutdown has no completion output and intentionally does not report
      // strict ledger-audit failures. It must retain only release authority on
      // failure, so use the same best-effort cleanup as poison recovery.
      cancel_status = cancel_generation_locked(
        prepared_binding.generation, 1'b1
      );
      if (cancel_status == null || !cancel_status.ok()) begin
        status = (cancel_status == null) ?
          invalid_state("CMQ shutdown cancellation returned null") :
          cancel_status;
        engine_lock.put(1);
        return;
      end
    end
    // shutdown has no completion output; cancellation and any older
    // undelivered results are deliberately discarded after ledger cleanup.
    terminal_fifo.delete();
    diagnostic_fifo.delete();
    late_final_fifo.delete();
    if (backing_mapping == null || host_mem == null) begin
      retain_release_authority(backing_mapping, host_mem);
      status = invalid_state("CMQ shutdown release authority is missing");
      engine_lock.put(1);
      return;
    end
    if (backing_release_opaque)
      release_status = host_mem.release_opaque(backing_mapping);
    else
      release_status = host_mem.\release (backing_mapping);
    if (release_status == null) begin
      retain_release_authority(backing_mapping, host_mem,
                               backing_release_opaque);
      status = invalid_state("CMQ shutdown release returned null status");
      engine_lock.put(1);
      return;
    end
    if (!release_status.ok()) begin
      retain_release_authority(backing_mapping, host_mem,
                               backing_release_opaque);
      status = release_status;
      engine_lock.put(1);
      return;
    end
    clear_configuration();
    engine_state = RDMA_CMQ_ENGINE_UNCONFIGURED;
    status = rdma_status::success();
    engine_lock.put(1);
  endtask
endclass

// 功能：在 doorbell 即将进入 MMIO 时把本 exact observer 交给 owner 认证与 arm。
// 输入/输出及副作用：无显式输入/返回值；已配置时同步调用
//   owner.arm_submission_for_mmio(this)，成功副作用由 engine 入口定义。
// 失败/边界：未配置或 owner=null 仅发布单一稳定 UVM_ERROR 并返回；
//   不解引用 null owner，不等待、分配、取锁或调用 scheduler/service/adapter。
function void
rdma_cmq_mmio_arm_observer::before_mmio_maybe_visible();
  if (!configured || owner == null) begin
    `uvm_error("RDMA_CMQ_MMIO_ARM_INVALID",
               "CMQ MMIO arm capability is invalid")
    return;
  end
  owner.arm_submission_for_mmio(this);
endfunction
