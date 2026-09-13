// 目录：测试层 unit/rdma_cmq_engine_test.sv。
// 职责：验证 CMQ engine/transport 的配置、提交、完成、恢复和生命周期边界。
// 依赖：依赖 rdma_core_pkg、UVM、Host-memory/PCIe mock、profile 和故障 fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；DUT 保存的 adapter/scheduler
//   引用均不转移所有权，mock backing 由对应场景显式 reset/shutdown 释放。

// 中文说明：rdma_cmq_engine_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

typedef enum int unsigned {
  RDMA_CMQ_TEST_SQE_GOOD,
  RDMA_CMQ_TEST_SQE_NULL,
  RDMA_CMQ_TEST_SQE_SHORT,
  RDMA_CMQ_TEST_SQE_BAD_ALIGNMENT,
  RDMA_CMQ_TEST_SQE_BAD_KIND,
  RDMA_CMQ_TEST_SQE_STALE_GENERATION,
  RDMA_CMQ_TEST_SQE_BAD_TARGET_KIND,
  RDMA_CMQ_TEST_SQE_BAD_TARGET_ADDRESS,
  RDMA_CMQ_TEST_EXPECTED_NULL,
  RDMA_CMQ_TEST_EXPECTED_INVALID,
  RDMA_CMQ_TEST_SQE_INACTIVE_HMC,
  RDMA_CMQ_TEST_SQE_INACTIVE_BAR,
  RDMA_CMQ_TEST_SQE_CLONE_SELF,
  RDMA_CMQ_TEST_SQE_CLONE_MUTATE,
  RDMA_CMQ_TEST_EXPECTED_CLONE_SELF,
  RDMA_CMQ_TEST_EXPECTED_CLONE_MUTATE
} rdma_cmq_test_sqe_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_DB_GOOD,
  RDMA_CMQ_TEST_DB_NULL,
  RDMA_CMQ_TEST_DB_BAD_LENGTH,
  RDMA_CMQ_TEST_DB_BAD_KIND,
  RDMA_CMQ_TEST_DB_STALE_GENERATION,
  RDMA_CMQ_TEST_DB_BAD_TARGET_KIND,
  RDMA_CMQ_TEST_DB_INACTIVE_BACKING,
  RDMA_CMQ_TEST_DB_INACTIVE_HMC,
  RDMA_CMQ_TEST_DB_CLONE_SELF,
  RDMA_CMQ_TEST_DB_CLONE_MUTATE
} rdma_cmq_test_doorbell_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_DB_INPUT_GOOD,
  RDMA_CMQ_TEST_DB_INPUT_MUTATE_SUCCESS,
  RDMA_CMQ_TEST_DB_INPUT_MUTATE_FAILURE,
  RDMA_CMQ_TEST_DB_INPUT_MUTATE_NULL
} rdma_cmq_test_doorbell_input_fault_e;

typedef enum bit [2:0] {
  RDMA_CMQ_TEST_CLONE_GOOD,
  RDMA_CMQ_TEST_CLONE_NULL,
  RDMA_CMQ_TEST_CLONE_SELF,
  RDMA_CMQ_TEST_CLONE_MUTATE,
  RDMA_CMQ_TEST_CLONE_WRONG_TYPE,
  RDMA_CMQ_TEST_CLONE_ALIAS
} rdma_cmq_test_clone_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_HOOK_GOOD,
  RDMA_CMQ_TEST_HOOK_NULL_STATUS,
  RDMA_CMQ_TEST_HOOK_NONOK_STATUS,
  RDMA_CMQ_TEST_HOOK_NULL_OUTPUT,
  RDMA_CMQ_TEST_HOOK_WRONG_TYPE,
  RDMA_CMQ_TEST_HOOK_SELF_OUTPUT,
  RDMA_CMQ_TEST_HOOK_MUTATED_OUTPUT,
  RDMA_CMQ_TEST_HOOK_ALIASED_OUTPUT,
  RDMA_CMQ_TEST_HOOK_NULL_VALIDATION,
  RDMA_CMQ_TEST_HOOK_FAILED_VALIDATION,
  RDMA_CMQ_TEST_HOOK_STATEFUL_SAME_DRIFT,
  RDMA_CMQ_TEST_HOOK_STATEFUL_DETACH_DRIFT,
  RDMA_CMQ_TEST_HOOK_MUTATE_SOURCE
} rdma_cmq_test_hook_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_DECODED_CONTRACT_GOOD,
  RDMA_CMQ_TEST_DECODED_ZERO_NONOK,
  RDMA_CMQ_TEST_DECODED_ZERO_HARDWARE_VALID,
  RDMA_CMQ_TEST_DECODED_NONZERO_OK,
  RDMA_CMQ_TEST_DECODED_NONZERO_HARDWARE_INVALID,
  RDMA_CMQ_TEST_DECODED_HARDWARE_MISMATCH,
  RDMA_CMQ_TEST_DECODED_CATEGORY_MISMATCH,
  RDMA_CMQ_TEST_DECODED_SEVERITY_MISMATCH,
  RDMA_CMQ_TEST_DECODED_NONZERO_WARNING,
  RDMA_CMQ_TEST_DECODED_NONZERO_FATAL
} rdma_cmq_test_decoded_contract_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_EMPTY_LEDGER_COUNTER,
  RDMA_CMQ_TEST_EMPTY_LEDGER_SLOT,
  RDMA_CMQ_TEST_EMPTY_LEDGER_TOKEN,
  RDMA_CMQ_TEST_EMPTY_LEDGER_REGISTRY
} rdma_cmq_test_empty_ledger_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_PUBLISHED_LEDGER_TOKEN_MISSING,
  RDMA_CMQ_TEST_PUBLISHED_LEDGER_SLOT_MISSING,
  RDMA_CMQ_TEST_PUBLISHED_LEDGER_REGISTRY_MISSING
} rdma_cmq_test_published_ledger_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_CANCEL_LEDGER_STRAY_TOKEN,
  RDMA_CMQ_TEST_CANCEL_LEDGER_MOVED_SLOT,
  RDMA_CMQ_TEST_CANCEL_LEDGER_DUPLICATE_SLOT,
  RDMA_CMQ_TEST_CANCEL_LEDGER_WRONG_COMMAND_KEY
} rdma_cmq_test_cancel_ledger_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_RECOVERY_X_COMMAND_ID,
  RDMA_CMQ_TEST_RECOVERY_X_ABSOLUTE_DEADLINE
} rdma_cmq_test_recovery_x_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_POISON_RESERVED_BIT,
  RDMA_CMQ_TEST_POISON_UNSUPPORTED_OPCODE,
  RDMA_CMQ_TEST_POISON_OPCODE_MISMATCH,
  RDMA_CMQ_TEST_POISON_UNKNOWN_ENTRY,
  RDMA_CMQ_TEST_POISON_NULL_DECODED,
  RDMA_CMQ_TEST_POISON_NULL_COMMAND_STATUS,
  RDMA_CMQ_TEST_POISON_SLOT_INCARNATION
} rdma_cmq_test_poison_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_EXTENSION_GOOD,
  RDMA_CMQ_TEST_EXTENSION_DROP_SCALAR,
  RDMA_CMQ_TEST_EXTENSION_ALIAS_EDGE,
  RDMA_CMQ_TEST_EXTENSION_NULL_OUTPUT,
  RDMA_CMQ_TEST_EXTENSION_MUTATE_SOURCE
} rdma_cmq_test_extension_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_DIRECT_HANDLE_GOOD,
  RDMA_CMQ_TEST_DIRECT_HANDLE_DROP_SCALAR,
  RDMA_CMQ_TEST_DIRECT_HANDLE_ALIAS_EDGE,
  RDMA_CMQ_TEST_DIRECT_HANDLE_SAME_DRIFT,
  RDMA_CMQ_TEST_DIRECT_HANDLE_DETACH_DRIFT
} rdma_cmq_test_direct_handle_fault_e;

typedef enum int unsigned {
  RDMA_CMQ_TEST_ABORT_SLOT_CONTEXT,
  RDMA_CMQ_TEST_ABORT_TICKET,
  RDMA_CMQ_TEST_ABORT_SLOT_RECORD,
  RDMA_CMQ_TEST_ABORT_DEPENDENCY,
  RDMA_CMQ_TEST_ABORT_DOORBELL_DESC,
  RDMA_CMQ_TEST_ABORT_PROFILE_OUTPUT
} rdma_cmq_test_abort_fault_e;

// 设计说明：hostile-factory matrix 显式枚举 production profile 支持的五种
// command-body dispatch，避免只用 object-ID fixture 得到无法证明其余分支的零计数。
typedef enum int unsigned {
  RDMA_CMQ_TEST_JOURNAL_BODY_QPC,
  RDMA_CMQ_TEST_JOURNAL_BODY_OBJECT_ID,
  RDMA_CMQ_TEST_JOURNAL_BODY_MR_DEREGISTER,
  RDMA_CMQ_TEST_JOURNAL_BODY_OCC_FLUSH,
  RDMA_CMQ_TEST_JOURNAL_BODY_EMPTY
} rdma_cmq_test_journal_body_e;

// 设计说明：orphan fault enum 让 probe 每次只向一张 retained 表注入一行，
// 从而独立证明 record/preallocation/profile/ticket-index 四个存在性方向。
typedef enum int unsigned {
  RDMA_CMQ_TEST_JOURNAL_ORPHAN_RECORD,
  RDMA_CMQ_TEST_JOURNAL_ORPHAN_PREALLOCATION,
  RDMA_CMQ_TEST_JOURNAL_ORPHAN_PROFILE,
  RDMA_CMQ_TEST_JOURNAL_ORPHAN_TICKET_INDEX
} rdma_cmq_test_journal_orphan_e;

// 设计说明：journal snapshot 必须绕过 raw UVM factory；该计数器把所有
//   hostile override 的构造汇聚为一个可观察值，避免测试依赖某个具体派生类。
class rdma_cmq_journal_factory_counter;
  local static int unsigned calls;

  // 功能：清零 journal hostile factory 构造计数，建立单次断言窗口。
  // 输入/输出及副作用：无输入输出；仅把静态 calls 置零。
  // 失败/边界：重复清零幂等；不清除 factory override，也不修改 DUT。
  static function void clear();
    calls = 0;
  endfunction

  // 功能：记录一次被 hostile override 截获的 raw-factory 对象构造。
  // 输入/输出及副作用：无输入输出；将静态 calls 加一。
  // 失败/边界：仅用于测试计数；计数溢出不代表生产资源 authority。
  static function void record_call();
    calls++;
  endfunction

  // 功能：返回当前 journal hostile factory 构造次数供测试断言。
  // 输入/输出及副作用：无输入；返回 calls，不修改 factory 或 DUT。
  // 失败/边界：未调用 clear 时包含既有窗口计数，调用方必须先建立边界。
  static function int unsigned call_count();
    return calls;
  endfunction
endclass

// 设计说明：以下 override 类型只在最后一个 hostile-factory 场景中安装；
//   direct-new snapshot 不会触发它们，任何 type_id::create 都留下统一计数。
class rdma_cmq_factory_trap_command extends rdma_cmq_command_desc;
  `uvm_object_utils(rdma_cmq_factory_trap_command)

  // 功能：构造 command factory trap 并记录一次禁止的 raw-factory 路径。
  // 输入/输出及副作用：name 传给父类；递增 journal factory 计数。
  // 失败/边界：对象仍是合法派生类型，测试以计数而非 cast fatal 判定违规。
  function new(string name = "rdma_cmq_factory_trap_command");
    super.new(name);
    rdma_cmq_journal_factory_counter::record_call();
  endfunction
endclass

class rdma_cmq_factory_trap_completion extends rdma_cmq_completion;
  `uvm_object_utils(rdma_cmq_factory_trap_completion)

  // 功能：构造 completion factory trap 并记录禁止的 raw-factory 路径。
  // 输入/输出及副作用：name 传给父类；递增 journal factory 计数。
  // 失败/边界：不主动 fatal；完整/partial publication 仍由 DUT 结果断言。
  function new(string name = "rdma_cmq_factory_trap_completion");
    super.new(name);
    rdma_cmq_journal_factory_counter::record_call();
  endfunction
endclass

class rdma_cmq_factory_trap_result extends rdma_cmq_execution_result;
  `uvm_object_utils(rdma_cmq_factory_trap_result)

  // 功能：构造 execution-result factory trap 并记录 raw-factory 使用。
  // 输入/输出及副作用：name 传给父类；递增 journal factory 计数。
  // 失败/边界：父类默认 fail-closed 字段不作为成功 snapshot 证据。
  function new(string name = "rdma_cmq_factory_trap_result");
    super.new(name);
    rdma_cmq_journal_factory_counter::record_call();
  endfunction
endclass

class rdma_cmq_factory_trap_record
  extends rdma_cmq_batch_submission_record;
  `uvm_object_utils(rdma_cmq_factory_trap_record)

  // 功能：构造 batch-record factory trap 并记录 raw-factory 使用。
  // 输入/输出及副作用：name 传给父类；递增 journal factory 计数。
  // 失败/边界：不复制源图，防止 trap 自身掩盖 partial-result 缺陷。
  function new(string name = "rdma_cmq_factory_trap_record");
    super.new(name);
    rdma_cmq_journal_factory_counter::record_call();
  endfunction
endclass

class rdma_cmq_factory_trap_recovery_request
  extends rdma_cmq_submission_recovery_request;
  `uvm_object_utils(rdma_cmq_factory_trap_recovery_request)

  // 功能：构造 recovery-request factory trap 并记录 raw-factory 使用。
  // 输入/输出及副作用：name 传给父类；递增 journal factory 计数。
  // 失败/边界：不取得 request 嵌套 authority，测试窗口结束后不再创建。
  function new(string name = "rdma_cmq_factory_trap_recovery_request");
    super.new(name);
    rdma_cmq_journal_factory_counter::record_call();
  endfunction
endclass

class rdma_cmq_factory_trap_proof extends rdma_cmq_reset_isolation_proof;
  `uvm_object_utils(rdma_cmq_factory_trap_proof)

  // 功能：构造 reset-proof factory trap 并记录 raw-factory 使用。
  // 输入/输出及副作用：name 传给父类；递增 journal factory 计数。
  // 失败/边界：默认 INVALID proof 不被当作有效 engine-minted authority。
  function new(string name = "rdma_cmq_factory_trap_proof");
    super.new(name);
    rdma_cmq_journal_factory_counter::record_call();
  endfunction
endclass

class rdma_cmq_factory_trap_qpc_body extends rdma_hw_qpc_command_body;
  `uvm_object_utils(rdma_cmq_factory_trap_qpc_body)

  // 功能：构造 QPC-body factory trap 并记录 polymorphic raw-factory 使用。
  // 输入/输出及副作用：name 传给父类；递增 journal factory 计数。
  // 失败/边界：不填充 QP handle；若泄漏到结果还会被 profile validation 拒绝。
  function new(string name = "rdma_cmq_factory_trap_qpc_body");
    super.new(name);
    rdma_cmq_journal_factory_counter::record_call();
  endfunction
endclass

class rdma_cmq_factory_trap_object_body
  extends rdma_hw_object_id_command_body;
  `uvm_object_utils(rdma_cmq_factory_trap_object_body)

  // 功能：构造 object-ID-body factory trap 并记录 raw-factory 使用。
  // 输入/输出及副作用：name 传给父类；递增 journal factory 计数。
  // 失败/边界：不复制 object_h，禁止 trap 假装为完整 detached body。
  function new(string name = "rdma_cmq_factory_trap_object_body");
    super.new(name);
    rdma_cmq_journal_factory_counter::record_call();
  endfunction
endclass

class rdma_cmq_factory_trap_mr_body
  extends rdma_hw_mr_deregister_body;
  `uvm_object_utils(rdma_cmq_factory_trap_mr_body)

  // 功能：构造 MR-body factory trap 并记录 polymorphic raw-factory 使用。
  // 输入/输出及副作用：name 传给父类；递增 journal factory 计数。
  // 失败/边界：默认空 MR handle 无 authority，不可成为有效 snapshot。
  function new(string name = "rdma_cmq_factory_trap_mr_body");
    super.new(name);
    rdma_cmq_journal_factory_counter::record_call();
  endfunction
endclass

class rdma_cmq_factory_trap_occ_body extends rdma_hw_occ_flush_body;
  `uvm_object_utils(rdma_cmq_factory_trap_occ_body)

  // 功能：构造 OCC-body factory trap 并记录 polymorphic raw-factory 使用。
  // 输入/输出及副作用：name 传给父类；递增 journal factory 计数。
  // 失败/边界：默认 selector 图案无效，不能掩盖未完整复制的 body。
  function new(string name = "rdma_cmq_factory_trap_occ_body");
    super.new(name);
    rdma_cmq_journal_factory_counter::record_call();
  endfunction
endclass

class rdma_cmq_factory_trap_empty_body extends rdma_hw_cmq_empty_body;
  `uvm_object_utils(rdma_cmq_factory_trap_empty_body)

  // 功能：构造 empty-body factory trap 并记录 polymorphic raw-factory 使用。
  // 输入/输出及副作用：name 传给父类；递增 journal factory 计数。
  // 失败/边界：即使 empty body 无字段，派生 wrapper 也不是合法 exact snapshot。
  function new(string name = "rdma_cmq_factory_trap_empty_body");
    super.new(name);
    rdma_cmq_journal_factory_counter::record_call();
  endfunction
endclass

class rdma_cmq_factory_trap_payload extends rdma_hw_cmq_completion;
  `uvm_object_utils(rdma_cmq_factory_trap_payload)

  // 功能：构造 completion-payload factory trap 并记录 raw-factory 使用。
  // 输入/输出及副作用：name 传给父类；递增 journal factory 计数。
  // 失败/边界：默认 payload 不复制源字段，不能满足值相等断言。
  function new(string name = "rdma_cmq_factory_trap_payload");
    super.new(name);
    rdma_cmq_journal_factory_counter::record_call();
  endfunction
endclass

// 设计说明：两个同名 profile 实例可具有不同 journal 语义；计数型派生类让测试
//   证明 retained batch 只调用安装时的 exact service handle，而非当前同名实例。
class rdma_cmq_journal_tracking_profile extends rdma_hw_cmq_hw_profile;
  `uvm_object_utils(rdma_cmq_journal_tracking_profile)

  string advertised_name;
  bit reject_journal_values;
  int unsigned journal_service_calls;

  // 功能：构造默认名为 rdma 的 tracking profile，并允许 production journal 值。
  // 输入/输出及副作用：name 传给 production profile；清零调用计数。
  // 失败/边界：父构造 codec/registry 失败由 validate_profile() 保留，不伪造可用状态。
  function new(string name = "rdma_cmq_journal_tracking_profile");
    super.new(name);
    advertised_name = "rdma";
    reject_journal_values = 1'b0;
    journal_service_calls = 0;
  endfunction

  // 功能：返回可变的测试 profile 名并记录一次 service dispatch。
  // 输入/输出及副作用：无输入；递增 journal_service_calls 后返回 advertised_name。
  // 失败/边界：空/漂移名字故意用于 query fail-closed，不自动回退为 rdma。
  virtual function string profile_name();
    journal_service_calls++;
    return advertised_name;
  endfunction

  // 功能：经 production seam 规范化 command body，同时记录 exact profile 调用。
  // 输入/输出及副作用：source 为输入，schema_tag/bytes 为输出；成功委托 super。
  // 失败/边界：reject_journal_values 时清空输出并稳定返回 INVALID_ARGUMENT。
  virtual function rdma_status canonicalize_command_body(
    input rdma_hw_model source,
    output string schema_tag,
    output byte unsigned canonical_field_bytes[]
  );
    journal_service_calls++;
    if (reject_journal_values) begin
      schema_tag = "";
      canonical_field_bytes = new[0];
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_ARGUMENT,
        "tracking profile rejects journal command bodies"
      );
    end
    return super.canonicalize_command_body(
      source, schema_tag, canonical_field_bytes
    );
  endfunction

  // 功能：经 production seam 复制 typed command body，并记录 exact profile 调用。
  // 输入/输出及副作用：source 为输入、snapshot 为输出；成功委托 super direct-new。
  // 失败/边界：reject_journal_values 时输出 null 与 INVALID_ARGUMENT，不发布 partial body。
  virtual function rdma_status snapshot_command_body(
    rdma_hw_model source,
    output rdma_hw_model snapshot
  );
    journal_service_calls++;
    if (reject_journal_values) begin
      snapshot = null;
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_ARGUMENT,
        "tracking profile rejects journal command snapshots"
      );
    end
    return super.snapshot_command_body(source, snapshot);
  endfunction

  // 功能：记录并委托 command body 的完整值相等比较。
  // 输入/输出及副作用：lhs/rhs 为只读输入；递增计数并返回 production 比较结果。
  // 失败/边界：null/未知 wrapper 由 super 返回 0；不修改任一 body。
  virtual function bit same_command_body_value(
    rdma_hw_model lhs,
    rdma_hw_model rhs
  );
    journal_service_calls++;
    return super.same_command_body_value(lhs, rhs);
  endfunction

  // 功能：记录并委托 command body graph 的跨图分离检查。
  // 输入/输出及副作用：source/snapshot 为只读输入；递增计数后返回 bit。
  // 失败/边界：未知节点或任一交叉别名由 super 返回 0，不修改图。
  virtual function bit command_body_graph_detached(
    rdma_hw_model source,
    rdma_hw_model snapshot
  );
    journal_service_calls++;
    return super.command_body_graph_detached(source, snapshot);
  endfunction

  // 功能：经 production seam 复制 typed completion payload 并记录 exact 调用。
  // 输入/输出及副作用：source 为输入、snapshot 为输出；成功发布 detached payload。
  // 失败/边界：reject_journal_values 时返回 INVALID_ARGUMENT/null，不调用 super。
  virtual function rdma_status snapshot_completion_payload(
    uvm_object source,
    output uvm_object snapshot
  );
    journal_service_calls++;
    if (reject_journal_values) begin
      snapshot = null;
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_ARGUMENT,
        "tracking profile rejects journal completion snapshots"
      );
    end
    return super.snapshot_completion_payload(source, snapshot);
  endfunction

  // 功能：记录并委托 completion payload 的完整字段比较。
  // 输入/输出及副作用：lhs/rhs 为只读输入；递增计数并返回 production 结果。
  // 失败/边界：非 exact payload 或字段不等由 super 返回 0，不修改 payload。
  virtual function bit same_completion_payload_value(
    uvm_object lhs,
    uvm_object rhs
  );
    journal_service_calls++;
    return super.same_completion_payload_value(lhs, rhs);
  endfunction

  // 功能：记录并委托 completion payload 外层对象的分离检查。
  // 输入/输出及副作用：source/snapshot 为只读输入；递增计数后返回 bit。
  // 失败/边界：null、非 exact wrapper 或外层别名由 super 返回 0。
  virtual function bit completion_payload_graph_detached(
    uvm_object source,
    uvm_object snapshot
  );
    journal_service_calls++;
    return super.completion_payload_graph_detached(source, snapshot);
  endfunction
endclass

class rdma_cmq_clone_fault_function_handle extends rdma_function_handle;
  `uvm_object_utils(rdma_cmq_clone_fault_function_handle)

  local static int unsigned fault_clone_calls;
  rdma_cmq_test_clone_fault_e clone_fault;
  rdma_function_handle alias_target;
  bit alias_once;

  // 功能：构造 rdma_cmq_clone_fault_function_handle，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：clone_fault=RDMA_CMQ_TEST_CLONE_GOOD；alias_target=null；alias_once=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_clone_fault_function_handle 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_clone_fault_function_handle");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
    alias_target = null;
    alias_once = 1'b0;
  endfunction

  // 功能：在 rdma_cmq_clone_fault_function_handle 中，clear_fault_clone_calls 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_fault_clone_calls 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  static function void clear_fault_clone_calls();
    fault_clone_calls = 0;
  endfunction

  // 功能：fault_clone_call_count 复制 当前对象字段 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：无显式参数；fault_clone_call_count 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：fault_clone_call_count 的结果直接由 return fault_clone_calls 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  static function int unsigned fault_clone_call_count();
    return fault_clone_calls;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_clone_fault_function_handle 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：rdma_status、clone_fault、alias_once 并使用字段 alias_once；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  virtual function uvm_object clone();
    if (clone_fault != RDMA_CMQ_TEST_CLONE_GOOD)
      fault_clone_calls++;
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_MUTATE: begin
        object_id++;
        return super.clone();
      end
      RDMA_CMQ_TEST_CLONE_WRONG_TYPE:
        return rdma_status::success("wrong Function clone type");
      RDMA_CMQ_TEST_CLONE_ALIAS: begin
        if (alias_once) begin
          alias_once = 1'b0;
          return alias_target;
        end
        return super.clone();
      end
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_clone_fault_handle extends rdma_handle;
  `uvm_object_utils(rdma_cmq_clone_fault_handle)

  rdma_cmq_test_clone_fault_e clone_fault;
  rdma_handle alias_target;

  // 功能：构造 rdma_cmq_clone_fault_handle，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：clone_fault=RDMA_CMQ_TEST_CLONE_GOOD；alias_target=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_clone_fault_handle 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_clone_fault_handle");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
    alias_target = null;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_clone_fault_handle 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：rdma_status、alias_target 并使用字段 rdma_status、alias_target；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_MUTATE: begin
        object_id++;
        return super.clone();
      end
      RDMA_CMQ_TEST_CLONE_WRONG_TYPE:
        return rdma_status::success("wrong handle clone type");
      RDMA_CMQ_TEST_CLONE_ALIAS: return alias_target;
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_clone_fault_qpc extends rdma_qpc_model;
  `uvm_object_utils(rdma_cmq_clone_fault_qpc)

  rdma_cmq_test_clone_fault_e clone_fault;

  // 功能：构造 rdma_cmq_clone_fault_qpc，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：clone_fault=RDMA_CMQ_TEST_CLONE_GOOD。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_clone_fault_qpc 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_clone_fault_qpc");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_clone_fault_qpc 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：rdma_status 并使用字段 rdma_status；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_MUTATE: begin
        host_id++;
        return super.clone();
      end
      RDMA_CMQ_TEST_CLONE_WRONG_TYPE:
        return rdma_status::success("wrong QPC clone type");
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_scalar_extension_qpc extends rdma_qpc_model;
  `uvm_object_utils(rdma_cmq_scalar_extension_qpc)

  local static int unsigned hostile_clone_calls;

  int unsigned extension_value;

  // 功能：构造 rdma_cmq_scalar_extension_qpc，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：extension_value=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_scalar_extension_qpc 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_scalar_extension_qpc");
    super.new(name);
    extension_value = 0;
  endfunction

  // 功能：在 rdma_cmq_scalar_extension_qpc 中，clear_hostile_clone_calls 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_hostile_clone_calls 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  static function void clear_hostile_clone_calls();
    hostile_clone_calls = 0;
  endfunction

  // 功能：在 rdma_cmq_scalar_extension_qpc 中，clone_call_count 将 rhs 中 rdma_cmq_scalar_extension_qpc 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone_call_count 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：clone_call_count 的结果直接由 return hostile_clone_calls 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  static function int unsigned clone_call_count();
    return hostile_clone_calls;
  endfunction

  // 功能：在 rdma_cmq_scalar_extension_qpc 中，clone 将 rhs 中 rdma_cmq_scalar_extension_qpc 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取局部计算结果，并使用字段 result；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  virtual function uvm_object clone();
    rdma_cmq_scalar_extension_qpc result;

    hostile_clone_calls++;
    result = rdma_cmq_scalar_extension_qpc::type_id::create(
      "lossy_scalar_extension_clone"
    );
    result.copy(this);
    return result;
  endfunction
endclass

class rdma_cmq_edge_extension_qpc extends rdma_qpc_model;
  `uvm_object_utils(rdma_cmq_edge_extension_qpc)

  local static int unsigned hostile_clone_calls;

  rdma_handle extension_h;

  // 功能：构造 rdma_cmq_edge_extension_qpc，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：extension_h=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_edge_extension_qpc 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_edge_extension_qpc");
    super.new(name);
    extension_h = null;
  endfunction

  // 功能：在 rdma_cmq_edge_extension_qpc 中，clear_hostile_clone_calls 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_hostile_clone_calls 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  static function void clear_hostile_clone_calls();
    hostile_clone_calls = 0;
  endfunction

  // 功能：在 rdma_cmq_edge_extension_qpc 中，clone_call_count 将 rhs 中 rdma_cmq_edge_extension_qpc 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone_call_count 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：clone_call_count 的结果直接由 return hostile_clone_calls 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  static function int unsigned clone_call_count();
    return hostile_clone_calls;
  endfunction

  // 功能：在 rdma_cmq_edge_extension_qpc 中，clone 将 rhs 中 rdma_cmq_edge_extension_qpc 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取局部计算结果，并使用字段 result、result.extension_h；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  virtual function uvm_object clone();
    rdma_cmq_edge_extension_qpc result;

    hostile_clone_calls++;
    result = rdma_cmq_edge_extension_qpc::type_id::create(
      "aliasing_edge_extension_clone"
    );
    result.copy(this);
    result.extension_h = extension_h;
    return result;
  endfunction
endclass

class rdma_cmq_scalar_extension_function_handle
    extends rdma_function_handle;
  `uvm_object_utils(rdma_cmq_scalar_extension_function_handle)

  int unsigned extension_value;

  // 功能：构造 rdma_cmq_scalar_extension_function_handle，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：extension_value=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_scalar_extension_function_handle 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(
    string name = "rdma_cmq_scalar_extension_function_handle"
  );
    super.new(name);
    extension_value = 0;
  endfunction
endclass

class rdma_cmq_edge_extension_handle extends rdma_handle;
  `uvm_object_utils(rdma_cmq_edge_extension_handle)

  rdma_handle extension_h;

  // 功能：构造 rdma_cmq_edge_extension_handle，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：extension_h=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_edge_extension_handle 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_edge_extension_handle");
    super.new(name);
    extension_h = null;
  endfunction
endclass

class rdma_cmq_clone_fault_page_layout extends rdma_page_table_layout;
  `uvm_object_utils(rdma_cmq_clone_fault_page_layout)

  rdma_cmq_test_clone_fault_e clone_fault;

  // 功能：构造 rdma_cmq_clone_fault_page_layout，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：clone_fault=RDMA_CMQ_TEST_CLONE_GOOD。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_clone_fault_page_layout 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_clone_fault_page_layout");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_clone_fault_page_layout 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：rdma_status 并使用字段 rdma_status；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_WRONG_TYPE:
        return rdma_status::success("wrong page-layout clone type");
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_clone_fault_mr_page_layout extends rdma_mr_page_layout;
  `uvm_object_utils(rdma_cmq_clone_fault_mr_page_layout)

  rdma_cmq_test_clone_fault_e clone_fault;

  // 功能：构造 rdma_cmq_clone_fault_mr_page_layout，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：clone_fault=RDMA_CMQ_TEST_CLONE_GOOD。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_clone_fault_mr_page_layout 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_clone_fault_mr_page_layout");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_clone_fault_mr_page_layout 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：rdma_status 并使用字段 rdma_status；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_WRONG_TYPE:
        return rdma_status::success("wrong MR-layout clone type");
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_clone_fault_ring extends rdma_ring_position;
  `uvm_object_utils(rdma_cmq_clone_fault_ring)

  rdma_cmq_test_clone_fault_e clone_fault;
  rdma_ring_position alias_target;

  // 功能：构造 rdma_cmq_clone_fault_ring，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：clone_fault=RDMA_CMQ_TEST_CLONE_GOOD；alias_target=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_clone_fault_ring 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_clone_fault_ring");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
    alias_target = null;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_clone_fault_ring 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：rdma_status、alias_target 并使用字段 rdma_status、alias_target；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_MUTATE: begin
        index++;
        return super.clone();
      end
      RDMA_CMQ_TEST_CLONE_WRONG_TYPE:
        return rdma_status::success("wrong ring clone type");
      RDMA_CMQ_TEST_CLONE_ALIAS: return alias_target;
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_clone_fault_aeqc extends rdma_aeqc_model;
  `uvm_object_utils(rdma_cmq_clone_fault_aeqc)

  rdma_cmq_test_clone_fault_e clone_fault;

  // 功能：构造 rdma_cmq_clone_fault_aeqc，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：clone_fault=RDMA_CMQ_TEST_CLONE_GOOD。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_clone_fault_aeqc 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_clone_fault_aeqc");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_clone_fault_aeqc 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：clone_fault 并使用字段 clone_fault；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 先检查 clone_fault == RDMA_CMQ_TEST_CLONE_MUTATE，再返回 super.clone()；拒绝分支不提交部分状态，也不隐式重试。
  virtual function uvm_object clone();
    if (clone_fault == RDMA_CMQ_TEST_CLONE_MUTATE) begin
      vector_id++;
      return super.clone();
    end
    return super.clone();
  endfunction
endclass

class rdma_cmq_unknown_body extends rdma_hw_model;
  `uvm_object_utils(rdma_cmq_unknown_body)

  // 功能：构造 rdma_cmq_unknown_body，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_unknown_body 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_unknown_body");
    super.new(name);
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 的结果直接由 return rdma_status::success() 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_status validate();
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return "unknown CMQ body";
  endfunction
endclass

// 设计说明：completion payload 的未知 exact wrapper 必须由 profile seam
//   非致命拒绝；独立类型避免把 command-body dispatch 与 payload dispatch 混淆。
class rdma_cmq_unknown_completion_payload extends uvm_object;
  `uvm_object_utils(rdma_cmq_unknown_completion_payload)

  int unsigned marker;

  // 功能：构造 unknown completion payload fixture，并保留可观察 marker。
  // 输入/输出及副作用：name 传给父类；marker 初始化为零，无外部副作用。
  // 失败/边界：该对象故意不属于任何 production payload schema，不能被 journal 发布。
  function new(string name = "rdma_cmq_unknown_completion_payload");
    super.new(name);
    marker = 0;
  endfunction
endclass

class rdma_cmq_profile_hook_body extends rdma_hw_model;
  `uvm_object_utils(rdma_cmq_profile_hook_body)

  local static int unsigned hostile_clone_calls;

  int unsigned value;
  rdma_handle nested_h;
  bit validation_returns_null;
  bit validation_fails;
  bit first_clone_succeeds;
  int unsigned clone_calls;

  // 功能：构造 rdma_cmq_profile_hook_body，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：value=0；nested_h=null；validation_returns_null=1'b0；validation_fails=1'b0；first_clone_succeeds=1'b0；clone_calls=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_profile_hook_body 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_profile_hook_body");
    super.new(name);
    value = 0;
    nested_h = null;
    validation_returns_null = 1'b0;
    validation_fails = 1'b0;
    first_clone_succeeds = 1'b0;
    clone_calls = 0;
  endfunction

  // 功能：在 rdma_cmq_profile_hook_body 中，clear_hostile_clone_calls 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_hostile_clone_calls 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  static function void clear_hostile_clone_calls();
    hostile_clone_calls = 0;
  endfunction

  // 功能：在 rdma_cmq_profile_hook_body 中，clone_call_count 将 rhs 中 rdma_cmq_profile_hook_body 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone_call_count 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：clone_call_count 的结果直接由 return hostile_clone_calls 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  static function int unsigned clone_call_count();
    return hostile_clone_calls;
  endfunction

  // 功能：在 rdma_cmq_profile_hook_body 中，clone 将 rhs 中 rdma_cmq_profile_hook_body 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：first_clone_succeeds、clone_calls、nested_h 并使用字段 result、result.value、result.nested_h、nested_h.kind、nested_h.function_uid、nested_h.object_id、nested_h.generation；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（hostile custom CMQ body clone must not be called），不保留部分有效快照。
  virtual function uvm_object clone();
    rdma_cmq_profile_hook_body result;

    hostile_clone_calls++;
    clone_calls++;
    if (first_clone_succeeds && clone_calls == 1) begin
      result = rdma_cmq_profile_hook_body::type_id::create(
        "stateful_hook_snapshot"
      );
      result.value = value;
      result.nested_h = rdma_handle::type_id::create(
        "stateful_hook_snapshot_nested"
      );
      if (nested_h != null) begin
        result.nested_h.kind = nested_h.kind;
        result.nested_h.function_uid = nested_h.function_uid;
        result.nested_h.object_id = nested_h.object_id;
        result.nested_h.generation = nested_h.generation;
      end
      return result;
    end
    `uvm_fatal("RDMA_COPY_TYPE",
               "hostile custom CMQ body clone must not be called")
    return null;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“injected custom CMQ body snapshot validation failure”；“custom CMQ body handle is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、validation_returns_null、validation_fails、nested_h 并使用字段 rdma_status、validation_returns_null、validation_fails、nested_h；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；具体拒绝条件包括 “injected custom CMQ body snapshot validation failure”；“custom CMQ body handle is null”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  virtual function rdma_status validate();
    if (validation_returns_null)
      return null;
    if (validation_fails)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "injected custom CMQ body snapshot validation failure"
      );
    if (nested_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "custom CMQ body handle is null");
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("custom hook body value=%0d", value);
  endfunction
endclass

class rdma_cmq_copy_fatal_catcher extends uvm_report_catcher;
  int unsigned caught_count;

  // 功能：构造 rdma_cmq_copy_fatal_catcher，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：caught_count=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_copy_fatal_catcher 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_copy_fatal_catcher");
    super.new(name);
    caught_count = 0;
  endfunction

  // 功能：在 rdma_cmq_copy_fatal_catcher 中，catch 控制 catch 对应的等待、异常或同步边界，按超时/捕获结果返回状态，不吞掉原始错误。
  // 输入/输出及副作用：无显式参数；catch 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 action_e，不取得调用方资源所有权。
  // 失败/边界：catch 超时或异常必须返回原始错误证据；不得无限等待或跳过同步边界。
  virtual function action_e catch();
    if (get_severity() == UVM_FATAL && get_id() == "RDMA_COPY_TYPE") begin
      caught_count++;
      return CAUGHT;
    end
    return THROW;
  endfunction
endclass

// 设计说明：arm capability 的所有拒绝分支必须收敛到同一个稳定
//   诊断；本 catcher 只吞掉该精确 ID/message，使其他 UVM_ERROR 仍污染汇总。
class rdma_cmq_mmio_arm_error_catcher extends uvm_report_catcher;
  int unsigned caught_count;

  // 功能：构造一个尚未捕获 MMIO arm 非法调用诊断的计数器。
  // 输入/输出及副作用：name 传给父类；caught_count 清零。
  // 失败/边界：构造不自动注册 callback，测试窗口必须显式 add/delete。
  function new(string name = "rdma_cmq_mmio_arm_error_catcher");
    super.new(name);
    caught_count = 0;
  endfunction

  // 功能：捕获且计数唯一允许的 MMIO arm capability 非法调用诊断。
  // 输入/输出及副作用：读取当前 severity/ID/message；精确命中返回
  //   CAUGHT 并递增 caught_count，其余 report 原样 THROW。
  // 失败/边界：ID 或 message 漂移时不吞掉；不将其他 error/fatal 降级。
  virtual function action_e catch();
    if (get_severity() == UVM_ERROR &&
        get_id() == "RDMA_CMQ_MMIO_ARM_INVALID" &&
        get_message() == "CMQ MMIO arm capability is invalid") begin
      caught_count++;
      return CAUGHT;
    end
    return THROW;
  endfunction
endclass

// 设计说明：hostile raw-factory 窗口要求任何 fatal 都成为可断言证据而不是终止
//   仿真；测试结束后立即移除 catcher，避免改变其他场景的 UVM 语义。
class rdma_cmq_journal_fatal_catcher extends uvm_report_catcher;
  int unsigned caught_count;
  int unsigned factory_type_count;

  // 功能：构造 journal fatal catcher，清零总 fatal 与 FCTTYP 子计数。
  // 输入/输出及副作用：name 传给父类；只初始化本地计数器。
  // 失败/边界：构造不会自动注册 callback，调用方必须显式 add/delete。
  function new(string name = "rdma_cmq_journal_fatal_catcher");
    super.new(name);
    caught_count = 0;
    factory_type_count = 0;
  endfunction

  // 功能：捕获 hostile-factory 窗口内的全部 UVM_FATAL，并单独识别 FCTTYP。
  // 输入/输出及副作用：读取当前 report 的 severity/id；命中时递增计数并返回 CAUGHT。
  // 失败/边界：非 fatal 原样 THROW；该 helper 不把被捕获 fatal 解释为测试成功。
  virtual function action_e catch();
    if (get_severity() == UVM_FATAL) begin
      caught_count++;
      if (get_id() == "FCTTYP")
        factory_type_count++;
      return CAUGHT;
    end
    return THROW;
  endfunction
endclass

class rdma_cmq_clone_fault_opcode_key extends rdma_cmq_opcode_key;
  `uvm_object_utils(rdma_cmq_clone_fault_opcode_key)

  rdma_cmq_test_clone_fault_e clone_fault;

  // 功能：构造 rdma_cmq_clone_fault_opcode_key，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：clone_fault=RDMA_CMQ_TEST_CLONE_GOOD。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_clone_fault_opcode_key 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_clone_fault_opcode_key");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_clone_fault_opcode_key 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：rdma_status、variant 并使用字段 variant；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_MUTATE: begin
        variant = {variant, "_mutated"};
        return super.clone();
      end
      RDMA_CMQ_TEST_CLONE_WRONG_TYPE:
        return rdma_status::success("wrong opcode clone type");
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_clone_fault_body extends rdma_cmq_sqe_model;
  `uvm_object_utils(rdma_cmq_clone_fault_body)

  rdma_cmq_test_clone_fault_e clone_fault;

  // 功能：构造 rdma_cmq_clone_fault_body，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：clone_fault=RDMA_CMQ_TEST_CLONE_GOOD。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_clone_fault_body 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_clone_fault_body");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_clone_fault_body 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：rdma_status 并使用字段 rdma_status；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_MUTATE: begin
        flags++;
        return super.clone();
      end
      RDMA_CMQ_TEST_CLONE_WRONG_TYPE:
        return rdma_status::success("wrong body clone type");
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_clone_fault_image extends rdma_hw_image;
  `uvm_object_utils(rdma_cmq_clone_fault_image)

  rdma_cmq_test_clone_fault_e clone_fault;

  // 功能：构造 rdma_cmq_clone_fault_image，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：clone_fault=RDMA_CMQ_TEST_CLONE_GOOD。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_clone_fault_image 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_clone_fault_image");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_clone_fault_image 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_MUTATE: begin
        if (bytes.size() == 0)
          length++;
        else
          bytes[0] ^= 8'hff;
        return super.clone();
      end
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_poll_raw_self_image extends rdma_hw_image;
  `uvm_object_utils(rdma_cmq_poll_raw_self_image)

  local static bit arm_next_raw_self_clone;
  local static bit arm_next_raw_stateful_clone;
  local static int unsigned total_clone_calls;
  bit self_clone;
  bit stateful_clone;
  int unsigned stateful_clone_calls;

  // 功能：构造 rdma_cmq_poll_raw_self_image，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：self_clone=1'b0；stateful_clone=1'b0；stateful_clone_calls=0；self_clone=1'b1；arm_next_raw_self_clone=1'b0；stateful_clone=1'b1；arm_next_raw_stateful_clone=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_poll_raw_self_image 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_poll_raw_self_image");
    super.new(name);
    self_clone = 1'b0;
    stateful_clone = 1'b0;
    stateful_clone_calls = 0;
    if (name == "cmq_raw_cqe" && arm_next_raw_self_clone) begin
      self_clone = 1'b1;
      arm_next_raw_self_clone = 1'b0;
    end
    else if (name == "cmq_raw_cqe" && arm_next_raw_stateful_clone) begin
      stateful_clone = 1'b1;
      arm_next_raw_stateful_clone = 1'b0;
    end
  endfunction

  // 功能：在 rdma_cmq_poll_raw_self_image 中，arm_next_raw 推进队列/事务游标或执行对应 I/O，并把结果写回声明的输出参数。
  // 输入/输出及副作用：无显式参数；arm_next_raw 读取 对象字段：arm_next_raw_self_clone 并使用字段 arm_next_raw_self_clone；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：arm_next_raw 无返回值，仅执行 arm_next_raw_self_clone=1'b1；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  static function void arm_next_raw();
    arm_next_raw_self_clone = 1'b1;
  endfunction

  // 功能：在 rdma_cmq_poll_raw_self_image 中，arm_next_raw_stateful 推进队列/事务游标或执行对应 I/O，并把结果写回声明的输出参数。
  // 输入/输出及副作用：无显式参数；arm_next_raw_stateful 读取 对象字段：arm_next_raw_stateful_clone 并使用字段 arm_next_raw_stateful_clone；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：arm_next_raw_stateful 无返回值，仅执行 arm_next_raw_stateful_clone=1'b1；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  static function void arm_next_raw_stateful();
    arm_next_raw_stateful_clone = 1'b1;
  endfunction

  // 功能：在 rdma_cmq_poll_raw_self_image 中，clear_clone_calls 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_clone_calls 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  static function void clear_clone_calls();
    total_clone_calls = 0;
  endfunction

  // 功能：在 rdma_cmq_poll_raw_self_image 中，clone_call_count 将 rhs 中 rdma_cmq_poll_raw_self_image 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone_call_count 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：clone_call_count 的结果直接由 return total_clone_calls 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  static function int unsigned clone_call_count();
    return total_clone_calls;
  endfunction

  // 功能：在 rdma_cmq_poll_raw_self_image 中，disarm 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；disarm 读取 对象字段：arm_next_raw_self_clone、arm_next_raw_stateful_clone 并使用字段 arm_next_raw_self_clone、arm_next_raw_stateful_clone；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：disarm 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  static function void disarm();
    arm_next_raw_self_clone = 1'b0;
    arm_next_raw_stateful_clone = 1'b0;
  endfunction

  // 功能：在 rdma_cmq_poll_raw_self_image 中，do_copy 将 rhs 中 rdma_cmq_poll_raw_self_image 的字段复制到当前对象，建立与源对象隔离的值快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（poll raw image copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_cmq_poll_raw_self_image rhs_image;

    super.do_copy(rhs);
    if (!$cast(rhs_image, rhs))
      `uvm_fatal("RDMA_COPY_TYPE",
                 "poll raw image copy type mismatch")
    self_clone = rhs_image.self_clone;
    stateful_clone = rhs_image.stateful_clone;
    stateful_clone_calls = rhs_image.stateful_clone_calls;
  endfunction

  // 功能：在 rdma_cmq_poll_raw_self_image 中，clone 将 rhs 中 rdma_cmq_poll_raw_self_image 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：self_clone、stateful_clone、stateful_clone_calls 并使用字段 cloned_object、stateful_clone；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 先检查 self_clone；stateful_clone；stateful_clone_calls == 2 && bytes.size(，再返回 this；cloned_object；super.clone()；拒绝分支不提交部分状态，也不隐式重试。
  virtual function uvm_object clone();
    uvm_object cloned_object;

    if (self_clone)
      return this;
    if (stateful_clone) begin
      total_clone_calls++;
      stateful_clone_calls++;
      if (stateful_clone_calls == 2 && bytes.size() != 0)
        bytes[0] ^= 8'hff;
      cloned_object = super.clone();
      if (stateful_clone_calls == 1)
        stateful_clone = 1'b0;
      return cloned_object;
    end
    return super.clone();
  endfunction
endclass

class rdma_cmq_self_clone_completion_payload extends uvm_object;
  `uvm_object_utils(rdma_cmq_self_clone_completion_payload)

  int unsigned value;
  rdma_handle nested_h;

  // 功能：构造 rdma_cmq_self_clone_completion_payload，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：value=0；nested_h=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_self_clone_completion_payload 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_self_clone_completion_payload");
    super.new(name);
    value = 0;
    nested_h = null;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_self_clone_completion_payload 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 的结果直接由 return this 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function uvm_object clone();
    return this;
  endfunction
endclass

class rdma_cmq_clone_fault_expected extends rdma_cmq_expected_response;
  `uvm_object_utils(rdma_cmq_clone_fault_expected)

  rdma_cmq_test_clone_fault_e clone_fault;

  // 功能：构造 rdma_cmq_clone_fault_expected，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：clone_fault=RDMA_CMQ_TEST_CLONE_GOOD。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_clone_fault_expected 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_clone_fault_expected");
    super.new(name);
    clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_clone_fault_expected 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：variant 并使用字段 variant；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_CMQ_TEST_CLONE_NULL: return null;
      RDMA_CMQ_TEST_CLONE_SELF: return this;
      RDMA_CMQ_TEST_CLONE_MUTATE: begin
        variant = {variant, "_mutated"};
        return super.clone();
      end
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_cmq_failing_slot_context extends rdma_cmq_slot_context;
  `uvm_object_utils(rdma_cmq_failing_slot_context)

  local static bit arm_failure;

  // 功能：构造 rdma_cmq_failing_slot_context，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_failing_slot_context 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_failing_slot_context");
    super.new(name);
  endfunction

  // 功能：在 rdma_cmq_failing_slot_context 中，arm 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：无显式参数；arm 读取 对象字段：arm_failure 并使用字段 arm_failure；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：arm 无返回值，仅执行 arm_failure=1'b1；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  static function void arm();
    arm_failure = 1'b1;
  endfunction

  // 功能：在 rdma_cmq_failing_slot_context 中，disarm 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；disarm 读取 对象字段：arm_failure 并使用字段 arm_failure；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：disarm 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  static function void disarm();
    arm_failure = 1'b0;
  endfunction

  // 功能：在 rdma_cmq_failing_slot_context 中，armed 判断 armed 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：无显式参数；armed 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：armed 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  static function bit armed();
    return arm_failure;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_failing_slot_context 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：arm_failure、sq_index 并使用字段 arm_failure；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 先检查 arm_failure && sq_index == 1，再返回 this；super.clone()；拒绝分支不提交部分状态，也不隐式重试。
  virtual function uvm_object clone();
    if (arm_failure && sq_index == 1) begin
      arm_failure = 1'b0;
      return this;
    end
    return super.clone();
  endfunction
endclass

class rdma_cmq_failing_ticket extends rdma_cmq_ticket;
  `uvm_object_utils(rdma_cmq_failing_ticket)

  local static bit arm_failure;

  // 功能：构造 rdma_cmq_failing_ticket，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_failing_ticket 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_failing_ticket");
    super.new(name);
  endfunction

  // 功能：在 rdma_cmq_failing_ticket 中，arm 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：无显式参数；arm 读取 对象字段：arm_failure 并使用字段 arm_failure；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：arm 无返回值，仅执行 arm_failure=1'b1；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  static function void arm();
    arm_failure = 1'b1;
  endfunction

  // 功能：在 rdma_cmq_failing_ticket 中，disarm 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；disarm 读取 对象字段：arm_failure 并使用字段 arm_failure；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：disarm 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  static function void disarm();
    arm_failure = 1'b0;
  endfunction

  // 功能：在 rdma_cmq_failing_ticket 中，armed 判断 armed 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：无显式参数；armed 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：armed 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  static function bit armed();
    return arm_failure;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_failing_ticket 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：arm_failure、sq_index 并使用字段 arm_failure；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 先检查 arm_failure && sq_index == 1，再返回 this；super.clone()；拒绝分支不提交部分状态，也不隐式重试。
  virtual function uvm_object clone();
    if (arm_failure && sq_index == 1) begin
      arm_failure = 1'b0;
      return this;
    end
    return super.clone();
  endfunction
endclass

class rdma_cmq_failing_slot_record extends rdma_cmq_slot_record;
  `uvm_object_utils(rdma_cmq_failing_slot_record)

  local static bit arm_failure;

  // 功能：构造 rdma_cmq_failing_slot_record，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_failing_slot_record 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_failing_slot_record");
    super.new(name);
  endfunction

  // 功能：在 rdma_cmq_failing_slot_record 中，arm 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：无显式参数；arm 读取 对象字段：arm_failure 并使用字段 arm_failure；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：arm 无返回值，仅执行 arm_failure=1'b1；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  static function void arm();
    arm_failure = 1'b1;
  endfunction

  // 功能：在 rdma_cmq_failing_slot_record 中，disarm 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；disarm 读取 对象字段：arm_failure 并使用字段 arm_failure；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：disarm 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  static function void disarm();
    arm_failure = 1'b0;
  endfunction

  // 功能：在 rdma_cmq_failing_slot_record 中，armed 判断 armed 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：无显式参数；armed 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：armed 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  static function bit armed();
    return arm_failure;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_failing_slot_record 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：arm_failure、sq_index 并使用字段 arm_failure；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 先检查 arm_failure && sq_index == 1，再返回 this；super.clone()；拒绝分支不提交部分状态，也不隐式重试。
  virtual function uvm_object clone();
    if (arm_failure && sq_index == 1) begin
      arm_failure = 1'b0;
      return this;
    end
    return super.clone();
  endfunction
endclass

class rdma_cmq_failing_dependency extends rdma_doorbell_dependency;
  `uvm_object_utils(rdma_cmq_failing_dependency)

  local static bit arm_failure;
  local static bit capture_armed;
  local static longint unsigned captured_dependency_id;

  // 功能：构造 rdma_cmq_failing_dependency，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_failing_dependency 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_failing_dependency");
    super.new(name);
  endfunction

  // 功能：在 rdma_cmq_failing_dependency 中，arm 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：无显式参数；arm 读取 对象字段：arm_failure 并使用字段 arm_failure；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：arm 无返回值，仅执行 arm_failure=1'b1；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  static function void arm();
    arm_failure = 1'b1;
  endfunction

  // 功能：在 rdma_cmq_failing_dependency 中，disarm 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；disarm 读取 对象字段：arm_failure 并使用字段 arm_failure；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：disarm 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  static function void disarm();
    arm_failure = 1'b0;
  endfunction

  // 功能：在 rdma_cmq_failing_dependency 中，armed 判断 armed 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：无显式参数；armed 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：armed 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  static function bit armed();
    return arm_failure;
  endfunction

  // 功能：在 rdma_cmq_failing_dependency 中，arm_capture 推进队列/事务游标或执行对应 I/O，并把结果写回声明的输出参数。
  // 输入/输出及副作用：无显式参数；arm_capture 读取 对象字段：capture_armed、captured_dependency_id 并使用字段 capture_armed、captured_dependency_id；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：arm_capture 无返回值，仅执行 capture_armed=1'b1、captured_dependency_id='0；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  static function void arm_capture();
    capture_armed = 1'b1;
    captured_dependency_id = '0;
  endfunction

  // 功能：在 rdma_cmq_failing_dependency 中，disarm_capture 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；disarm_capture 读取 对象字段：capture_armed、captured_dependency_id 并使用字段 capture_armed、captured_dependency_id；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：disarm_capture 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  static function void disarm_capture();
    capture_armed = 1'b0;
    captured_dependency_id = '0;
  endfunction

  // 功能：执行 take_captured_dependency_id 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：dependency_id（输出）；take_captured_dependency_id 读取 dependency_id 并使用字段 dependency_id，并写入 dependency_id；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：take_captured_dependency_id 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  static function bit take_captured_dependency_id(
    output longint unsigned dependency_id
  );
    dependency_id = captured_dependency_id;
    return !capture_armed;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_failing_dependency 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：capture_armed、arm_failure、relative_offset、captured_dependency_id 并使用字段 capture_armed、captured_dependency_id、arm_failure；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 先检查 capture_armed；arm_failure && relative_offset == 64，再返回 this；super.clone()；拒绝分支不提交部分状态，也不隐式重试。
  virtual function uvm_object clone();
    if (capture_armed) begin
      capture_armed = 1'b0;
      captured_dependency_id = dependency_id;
    end
    if (arm_failure && relative_offset == 64) begin
      arm_failure = 1'b0;
      return this;
    end
    return super.clone();
  endfunction
endclass

class rdma_cmq_failing_doorbell_desc extends rdma_doorbell_desc;
  `uvm_object_utils(rdma_cmq_failing_doorbell_desc)

  local static bit arm_failure;

  // 功能：构造 rdma_cmq_failing_doorbell_desc，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_failing_doorbell_desc 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_failing_doorbell_desc");
    super.new(name);
  endfunction

  // 功能：在 rdma_cmq_failing_doorbell_desc 中，arm 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：无显式参数；arm 读取 对象字段：arm_failure 并使用字段 arm_failure；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：arm 无返回值，仅执行 arm_failure=1'b1；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  static function void arm();
    arm_failure = 1'b1;
  endfunction

  // 功能：在 rdma_cmq_failing_doorbell_desc 中，disarm 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；disarm 读取 对象字段：arm_failure 并使用字段 arm_failure；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：disarm 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  static function void disarm();
    arm_failure = 1'b0;
  endfunction

  // 功能：在 rdma_cmq_failing_doorbell_desc 中，armed 判断 armed 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：无显式参数；armed 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：armed 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  static function bit armed();
    return arm_failure;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_failing_doorbell_desc 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：arm_failure 并使用字段 arm_failure；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 先检查 arm_failure，再返回 this；super.clone()；拒绝分支不提交部分状态，也不隐式重试。
  virtual function uvm_object clone();
    if (arm_failure) begin
      arm_failure = 1'b0;
      return this;
    end
    return super.clone();
  endfunction
endclass

class rdma_cmq_test_profile extends rdma_cmq_hw_profile;
  `uvm_object_utils(rdma_cmq_test_profile)

  localparam bit [31:0] TEST_OPCODE = 32'h0000_0010;
  localparam bit [31:0] TEST_OPCODE_A = 32'h0000_0010;
  localparam bit [31:0] TEST_OPCODE_B = 32'h0000_0020;
  localparam bit [31:0] TEST_OPCODE_UNSUPPORTED = 32'h0000_00ee;
  localparam longint unsigned TEST_DOORBELL_OFFSET = 64'h80;

  bit fail_validation;
  bit return_null_status;
  int unsigned validation_calls;
  rdma_cmq_test_sqe_fault_e sqe_fault;
  int unsigned sqe_fault_compose_call;
  rdma_cmq_test_doorbell_fault_e doorbell_fault;
  rdma_cmq_test_doorbell_input_fault_e doorbell_input_fault;
  bit [31:0] fail_compose_opcode;
  int unsigned null_compose_call;
  rdma_status_code_e compose_failure_code;
  bit fail_doorbell_encode;
  rdma_status_code_e doorbell_failure_code;
  rdma_byte_endian_e sqe_endian;
  int unsigned sqe_hardware_version;
  bit alternate_sqe_format_for_opcode_b;
  rdma_byte_endian_e alternate_sqe_endian;
  int unsigned alternate_sqe_hardware_version;
  int unsigned compose_calls;
  int unsigned doorbell_calls;
  int unsigned last_final_pi;
  bit last_polarity;
  rdma_handle last_doorbell_target;
  rdma_handle last_doorbell_input;
  rdma_cmq_expected_response last_expected_alias;
  bit mutate_raw_cqe_input;
  bit use_self_clone_completion_payload;
  rdma_cmq_self_clone_completion_payload last_completion_payload_source;
  rdma_cmq_test_hook_fault_e completion_payload_hook_fault;
  int unsigned completion_payload_same_calls;
  int unsigned completion_payload_detach_calls;
  rdma_cmq_test_decoded_contract_fault_e decoded_contract_fault;
  bit return_null_decoded;
  bit return_null_command_status;
  int unsigned inspect_calls;
  int unsigned inspect_failure_call;
  rdma_status_code_e inspect_failure_code;
  rdma_hw_cmq_completion_codec completion_codec;
  rdma_hw_error_codec error_codec;

  // 功能：构造 rdma_cmq_test_profile，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：fail_validation=1'b0；return_null_status=1'b0；validation_calls=0；sqe_fault=RDMA_CMQ_TEST_SQE_GOOD；sqe_fault_compose_call=0；doorbell_fault=RDMA_CMQ_TEST_DB_GOOD；doorbell_input_fault=RDMA_CMQ_TEST_DB_INPUT_GOOD；fail_compose_opcode='0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_test_profile 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_test_profile");
    super.new(name);
    fail_validation = 1'b0;
    return_null_status = 1'b0;
    validation_calls = 0;
    sqe_fault = RDMA_CMQ_TEST_SQE_GOOD;
    sqe_fault_compose_call = 0;
    doorbell_fault = RDMA_CMQ_TEST_DB_GOOD;
    doorbell_input_fault = RDMA_CMQ_TEST_DB_INPUT_GOOD;
    fail_compose_opcode = '0;
    null_compose_call = 0;
    compose_failure_code = RDMA_SC_CODEC_ERROR;
    fail_doorbell_encode = 1'b0;
    doorbell_failure_code = RDMA_SC_CODEC_ERROR;
    sqe_endian = RDMA_ENDIAN_BIG;
    sqe_hardware_version = 7;
    alternate_sqe_format_for_opcode_b = 1'b0;
    alternate_sqe_endian = RDMA_ENDIAN_LITTLE;
    alternate_sqe_hardware_version = 8;
    compose_calls = 0;
    doorbell_calls = 0;
    last_final_pi = 0;
    last_polarity = 1'b0;
    last_doorbell_target = null;
    last_doorbell_input = null;
    last_expected_alias = null;
    mutate_raw_cqe_input = 1'b0;
    use_self_clone_completion_payload = 1'b0;
    last_completion_payload_source = null;
    completion_payload_hook_fault = RDMA_CMQ_TEST_HOOK_GOOD;
    completion_payload_same_calls = 0;
    completion_payload_detach_calls = 0;
    decoded_contract_fault = RDMA_CMQ_TEST_DECODED_CONTRACT_GOOD;
    return_null_decoded = 1'b0;
    return_null_command_status = 1'b0;
    inspect_calls = 0;
    inspect_failure_call = 0;
    inspect_failure_code = RDMA_SC_CODEC_ERROR;
    completion_codec = rdma_hw_cmq_completion_codec::type_id::create(
      "engine_test_completion_codec"
    );
    error_codec = rdma_hw_error_codec::type_id::create(
      "engine_test_error_codec"
    );
  endfunction

  // 功能：在 rdma_cmq_test_profile 中，profile_name 返回该实现声明的固定 profile/资源属性，供注册表和上层选择正确的 codec 或生命周期策略。
  // 输入/输出及副作用：无显式参数；profile_name 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：profile_name 是只读访问器，返回 "cmq_engine_test"；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function string profile_name();
    return "cmq_engine_test";
  endfunction

  // 功能：validate_profile 校验 当前对象字段 与当前对象状态的一致性，并显式处理“test CMQ profile validation failed”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate_profile 读取 对象字段：rdma_status、return_null_status、fail_validation 并使用字段 rdma_status、return_null_status、fail_validation；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate_profile 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“test CMQ profile validation failed”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate_profile();
    validation_calls++;
    if (return_null_status)
      return null;
    if (fail_validation)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "test CMQ profile validation failed");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_cmq_test_profile 中，set_cqe_qword 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：image（输入）、qword_index（输入）、value（输入）；set_cqe_qword 先依据 依赖存在性、authority 和 generation 条件 校验 image、qword_index、value；成功时更新本对象配置/状态并保存非拥有引用，返回 void。
  // 失败/边界：set_cqe_qword 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function void set_cqe_qword(
    rdma_hw_image image,
    int unsigned qword_index,
    bit [63:0] value
  );
    int unsigned base;

    base = qword_index * 8;
    for (int unsigned i = 0; i < 8; i++)
      image.bytes[base + i] = value[63 - (i * 8) -: 8];
  endfunction

  // 功能：make_cqe 创建独立的 rdma_hw_image；根据 name、owner、hardware_opcode、hardware_ecode、wqe_index、wqe_wrap、function_generation 设置字段 image、image.length、image.alignment、image.endian、image.image_kind、image.hardware_version、image.function_generation、image.write_target_kind、image.backing_target、image.hmc_target，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、owner（输入）、hardware_opcode（输入）、hardware_ecode（输入）、wqe_index（输入）、wqe_wrap（输入）、function_generation（输入）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：make_cqe 的结果直接由 return image 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function rdma_hw_image make_cqe(
    string name,
    bit owner,
    bit [31:0] hardware_opcode,
    bit [31:0] hardware_ecode,
    int unsigned wqe_index,
    bit wqe_wrap,
    int unsigned function_generation
  );
    rdma_hw_image image;
    bit [63:0] qword0;

    image = rdma_hw_image::type_id::create(name);
    repeat (64)
      image.bytes.push_back(8'h00);
    image.length = 64;
    image.alignment = 64;
    image.endian = sqe_endian;
    image.image_kind = RDMA_IMAGE_CMQ_CQE;
    image.hardware_version = sqe_hardware_version;
    image.function_generation = function_generation;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;
    qword0 = '0;
    qword0[63] = owner;
    qword0[45] = wqe_wrap;
    qword0[44:40] = wqe_index[4:0];
    qword0[39:32] = hardware_opcode[7:0];
    qword0[31:24] = hardware_ecode[7:0];
    set_cqe_qword(image, 0, qword0);
    return image;
  endfunction

  // 功能：在 rdma_cmq_test_profile 中，compose_sqe 按 profile 的字段布局和端序把语义模型编码为硬件镜像，并在发布前检查长度与对齐。
  // 输入/输出及副作用：command（输入）、slot（输入）、sqe（输出）、expected（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：模型为空、字段越界、保留位非零或输出长度不足时返回编码错误，不发布部分图像。
  virtual function rdma_status compose_sqe(
    rdma_cmq_command_desc command,
    rdma_cmq_slot_context slot,
    output rdma_hw_image sqe,
    output rdma_cmq_expected_response expected
  );
    rdma_cmq_sqe_model body;
    rdma_cmq_clone_fault_image clone_fault_image;
    rdma_cmq_clone_fault_expected clone_fault_expected;

    sqe = null;
    expected = null;
    compose_calls++;
    if (command == null || command.opcode_key == null ||
        command.opcode_key.profile_name != profile_name())
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "test profile name is unsupported");
    if (!(command.opcode_key.opcode inside {TEST_OPCODE_A,
                                            TEST_OPCODE_B}))
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "test profile opcode is unsupported");
    if (slot == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "test profile slot is null");
    if (null_compose_call != 0 && compose_calls == null_compose_call) begin
      null_compose_call = 0;
      return null;
    end
    if (fail_compose_opcode != 0 &&
        command.opcode_key.opcode == fail_compose_opcode)
      return rdma_status::make(compose_failure_code,
                               "injected test profile compose failure");
    if (!$cast(body, command.body))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "test profile body type is invalid");
    if (sqe_fault == RDMA_CMQ_TEST_SQE_NULL)
      return rdma_status::success();
    sqe = rdma_hw_image::type_id::create("test_sqe");
    for (int unsigned i = 0; i < 64; i++)
      sqe.bytes.push_back(byte'(command.opcode_key.opcode[7:0] + i));
    sqe.bytes[0] = command.opcode_key.opcode[7:0];
    sqe.bytes[1] = body.flags[7:0];
    sqe.bytes[2] = (command.qpc_signature_source == null ||
                    command.qpc_signature_source.bytes.size() == 0) ?
                   8'h00 : command.qpc_signature_source.bytes[0];
    sqe.bytes[3] = command.function_h.object_id[7:0];
    sqe.bytes[4] = slot.sq_index[7:0];
    sqe.bytes[5] = {6'b0, !slot.sq_wrap, slot.sq_wrap};
    sqe.bytes[6] = slot.slot_sequence[7:0];
    sqe.bytes[7] = body.command_id[7:0];
    sqe.length = 64;
    sqe.alignment = 64;
    sqe.endian = (alternate_sqe_format_for_opcode_b &&
                  command.opcode_key.opcode == TEST_OPCODE_B) ?
                 alternate_sqe_endian : sqe_endian;
    sqe.image_kind = RDMA_IMAGE_CMQ_SQE;
    sqe.hardware_version =
      (alternate_sqe_format_for_opcode_b &&
       command.opcode_key.opcode == TEST_OPCODE_B) ?
      alternate_sqe_hardware_version : sqe_hardware_version;
    sqe.function_generation = command.function_h.generation;
    sqe.write_target_kind = RDMA_HW_TARGET_BACKING;
    sqe.backing_target.value = slot.backing_addr.value +
                               slot.relative_offset;
    expected = rdma_cmq_expected_response::type_id::create(
      "test_expected"
    );
    expected.hardware_opcode = command.opcode_key.opcode;
    expected.variant = $sformatf("expected_%02h_%02h",
                                 command.opcode_key.opcode[7:0],
                                 body.flags[7:0]);
    last_expected_alias = expected;
    if (sqe_fault_compose_call == 0 ||
        compose_calls == sqe_fault_compose_call) begin
      case (sqe_fault)
        RDMA_CMQ_TEST_SQE_SHORT: begin
          void'(sqe.bytes.pop_back());
          sqe.length = 63;
        end
        RDMA_CMQ_TEST_SQE_BAD_ALIGNMENT: sqe.alignment = 32;
        RDMA_CMQ_TEST_SQE_BAD_KIND: sqe.image_kind = RDMA_IMAGE_CMQ_CQE;
        RDMA_CMQ_TEST_SQE_STALE_GENERATION:
          sqe.function_generation++;
        RDMA_CMQ_TEST_SQE_BAD_TARGET_KIND:
          sqe.write_target_kind = RDMA_HW_TARGET_BAR;
        RDMA_CMQ_TEST_SQE_BAD_TARGET_ADDRESS:
          sqe.backing_target.value++;
        RDMA_CMQ_TEST_EXPECTED_NULL: expected = null;
        RDMA_CMQ_TEST_EXPECTED_INVALID: expected.variant = "";
        RDMA_CMQ_TEST_SQE_INACTIVE_HMC:
          sqe.hmc_target.value = 64'h40;
        RDMA_CMQ_TEST_SQE_INACTIVE_BAR:
          sqe.bar_target.value = 64'h80;
        RDMA_CMQ_TEST_SQE_CLONE_SELF,
        RDMA_CMQ_TEST_SQE_CLONE_MUTATE: begin
          clone_fault_image = rdma_cmq_clone_fault_image::type_id::create(
            "test_sqe_clone_fault"
          );
          clone_fault_image.copy(sqe);
          clone_fault_image.clone_fault =
            (sqe_fault == RDMA_CMQ_TEST_SQE_CLONE_SELF) ?
              RDMA_CMQ_TEST_CLONE_SELF : RDMA_CMQ_TEST_CLONE_MUTATE;
          sqe = clone_fault_image;
        end
        RDMA_CMQ_TEST_EXPECTED_CLONE_SELF,
        RDMA_CMQ_TEST_EXPECTED_CLONE_MUTATE: begin
          clone_fault_expected =
            rdma_cmq_clone_fault_expected::type_id::create(
              "test_expected_clone_fault"
            );
          clone_fault_expected.copy(expected);
          clone_fault_expected.clone_fault =
            (sqe_fault == RDMA_CMQ_TEST_EXPECTED_CLONE_SELF) ?
              RDMA_CMQ_TEST_CLONE_SELF : RDMA_CMQ_TEST_CLONE_MUTATE;
          expected = clone_fault_expected;
          last_expected_alias = expected;
        end
        default: begin
        end
      endcase
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_cmq_test_profile 中，inspect_cqe 从输入 image/bytes 按固定 offset 提取字段，交付解码所需的值。
  // 输入/输出及副作用：raw_cqe（输入）、expected_owner（输入）、ready（输出）、decoded（输出）；inspect_cqe 读取 raw_cqe、expected_owner、ready、decoded 并使用字段 ready、decoded、codec_raw_cqe、codec_raw_cqe.endian、codec_raw_cqe.hardware_version、status、cloned_object、decoded.hardware_opcode，并写入 ready、decoded；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：inspect_cqe 返回 RDMA_SC_INVALID_STATE、RDMA_SC_OK；具体拒绝条件包括 “injected test profile inspection failure”；“test profile completion codecs are unavailable”；“test profile could not snapshot its raw CQE input”；“test completion codec returned null decoded data”；“test error codec returned null status”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  virtual function rdma_status inspect_cqe(
    rdma_hw_image raw_cqe,
    bit expected_owner,
    output bit ready,
    output rdma_cmq_decoded_cqe decoded
  );
    rdma_status status;
    rdma_status command_status;
    rdma_hw_image codec_raw_cqe;
    rdma_hw_cmq_completion completion;
    rdma_hw_cmq_completion payload;
    rdma_cmq_self_clone_completion_payload hostile_payload;
    uvm_object cloned_object;

    inspect_calls++;
    ready = 1'b0;
    decoded = null;
    if (inspect_failure_call != 0 &&
        inspect_calls == inspect_failure_call)
      return rdma_status::make(
        inspect_failure_code, "injected test profile inspection failure"
      );
    if (completion_codec == null || error_codec == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "test profile completion codecs are unavailable"
      );
    codec_raw_cqe = rdma_cmq_clone_image_value(
      raw_cqe, "test profile XTR codec input"
    );
    if (codec_raw_cqe == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "test profile could not snapshot its raw CQE input"
      );
    // The synthetic profile deliberately advertises a non-XTR format to
    // exercise engine neutrality.  Only its private test codec adapter owns
    // the XTR v1 metadata required to decode the borrowed wire layout.
    codec_raw_cqe.endian = RDMA_ENDIAN_BIG;
    codec_raw_cqe.hardware_version = RDMA_HW_VERSION;
    status = completion_codec.inspect_completion(
      codec_raw_cqe, expected_owner, ready, completion
    );
    if (status == null || !status.ok() || !ready)
      return status;
    if (completion == null) begin
      ready = 1'b0;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "test completion codec returned null decoded data"
      );
    end
    status = error_codec.decode_status(
      completion.command_ecode, RDMA_ENGINE_CMQ, command_status
    );
    if (status == null || !status.ok() || command_status == null) begin
      ready = 1'b0;
      return (status == null) ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "test error codec returned null status"
        ) : status;
    end
    cloned_object = completion.clone();
    if (cloned_object == null || !$cast(payload, cloned_object)) begin
      ready = 1'b0;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "test completion payload clone failed"
      );
    end
    decoded = rdma_cmq_decoded_cqe::type_id::create(
      "engine_test_decoded_cqe"
    );
    if (decoded == null) begin
      ready = 1'b0;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "test decoded CQE allocation failed"
      );
    end
    decoded.hardware_opcode = {24'h0, completion.opcode};
    decoded.wqe_index = completion.wqe_index;
    decoded.wqe_wrap = completion.wrap;
    decoded.hardware_ecode = {24'h0, completion.command_ecode};
    decoded.command_status = command_status;
    if (return_null_decoded) begin
      decoded = null;
      return rdma_status::success();
    end
    if (return_null_command_status) begin
      decoded.command_status = null;
      return rdma_status::success();
    end
    case (decoded_contract_fault)
      RDMA_CMQ_TEST_DECODED_ZERO_NONOK: begin
        decoded.hardware_ecode = '0;
        decoded.command_status.code = RDMA_SC_INVALID_STATE;
        decoded.command_status.category =
          rdma_status::category_for(decoded.command_status.code);
        decoded.command_status.hardware_code = '0;
        decoded.command_status.hardware_code_valid = 1'b0;
        decoded.command_status.severity = RDMA_SEVERITY_INFO;
      end
      RDMA_CMQ_TEST_DECODED_ZERO_HARDWARE_VALID: begin
        decoded.hardware_ecode = '0;
        decoded.command_status.code = RDMA_SC_OK;
        decoded.command_status.category =
          rdma_status::category_for(decoded.command_status.code);
        decoded.command_status.hardware_code = 32'h1;
        decoded.command_status.hardware_code_valid = 1'b1;
        decoded.command_status.severity = RDMA_SEVERITY_INFO;
      end
      RDMA_CMQ_TEST_DECODED_NONZERO_OK: begin
        decoded.hardware_ecode = 32'h1;
        decoded.command_status.code = RDMA_SC_OK;
        decoded.command_status.category =
          rdma_status::category_for(decoded.command_status.code);
        decoded.command_status.hardware_code = decoded.hardware_ecode;
        decoded.command_status.hardware_code_valid = 1'b1;
        decoded.command_status.severity = RDMA_SEVERITY_ERROR;
      end
      RDMA_CMQ_TEST_DECODED_NONZERO_HARDWARE_INVALID: begin
        decoded.hardware_ecode = 32'h1;
        decoded.command_status.hardware_code = decoded.hardware_ecode;
        decoded.command_status.hardware_code_valid = 1'b0;
      end
      RDMA_CMQ_TEST_DECODED_HARDWARE_MISMATCH: begin
        decoded.hardware_ecode = 32'h1;
        decoded.command_status.hardware_code = 32'h2;
        decoded.command_status.hardware_code_valid = 1'b1;
      end
      RDMA_CMQ_TEST_DECODED_CATEGORY_MISMATCH: begin
        decoded.hardware_ecode = 32'h1;
        decoded.command_status.category =
          (rdma_status::category_for(decoded.command_status.code) ==
             RDMA_STATUS_STATE) ?
          RDMA_STATUS_CONFIGURATION : RDMA_STATUS_STATE;
      end
      RDMA_CMQ_TEST_DECODED_SEVERITY_MISMATCH: begin
        decoded.hardware_ecode = 32'h1;
        decoded.command_status.severity = RDMA_SEVERITY_INFO;
      end
      RDMA_CMQ_TEST_DECODED_NONZERO_WARNING: begin
        decoded.command_status.severity = RDMA_SEVERITY_WARNING;
      end
      RDMA_CMQ_TEST_DECODED_NONZERO_FATAL: begin
        decoded.command_status.severity = RDMA_SEVERITY_FATAL;
      end
      default: begin
      end
    endcase
    if (use_self_clone_completion_payload) begin
      hostile_payload =
        rdma_cmq_self_clone_completion_payload::type_id::create(
          "retained_self_clone_completion_payload"
        );
      hostile_payload.value = completion.object_payload.size();
      hostile_payload.nested_h = rdma_handle::type_id::create(
        "retained_self_clone_completion_payload_handle"
      );
      hostile_payload.nested_h.kind = RDMA_RESOURCE_CQ;
      hostile_payload.nested_h.function_uid = 64'h1234_5678_90ab_cdef;
      hostile_payload.nested_h.object_id = 32'h1357_2468;
      hostile_payload.nested_h.generation = raw_cqe.function_generation;
      decoded.response_payload = hostile_payload;
      last_completion_payload_source = hostile_payload;
    end
    else begin
      decoded.response_payload = payload;
      last_completion_payload_source = null;
    end
    status = decoded.validate();
    if (!status.ok()) begin
      decoded = null;
      ready = 1'b0;
      return status;
    end
    if (mutate_raw_cqe_input && raw_cqe.bytes.size() > 1)
      raw_cqe.bytes[1] ^= 8'hff;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_cmq_test_profile 中，snapshot_completion_payload 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：source（输入）、snapshot（输出）；snapshot_completion_payload 读取 source、snapshot 并使用字段 snapshot、snapshot_hostile、snapshot_hostile.value、snapshot_hostile.nested_h、nested_h.kind、nested_h.function_uid、nested_h.object_id、nested_h.generation，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：snapshot_completion_payload 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  virtual function rdma_status snapshot_completion_payload(
    uvm_object source,
    output uvm_object snapshot
  );
    rdma_cmq_self_clone_completion_payload source_hostile;
    rdma_cmq_self_clone_completion_payload snapshot_hostile;
    rdma_hw_cmq_completion source_xtr;
    rdma_hw_cmq_completion snapshot_xtr;

    snapshot = null;
    case (completion_payload_hook_fault)
      RDMA_CMQ_TEST_HOOK_NULL_STATUS: return null;
      RDMA_CMQ_TEST_HOOK_NONOK_STATUS:
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "injected completion payload snapshot rejection"
        );
      RDMA_CMQ_TEST_HOOK_NULL_OUTPUT: return rdma_status::success();
      RDMA_CMQ_TEST_HOOK_WRONG_TYPE: begin
        snapshot = rdma_status::success("wrong completion payload type");
        return rdma_status::success();
      end
      RDMA_CMQ_TEST_HOOK_SELF_OUTPUT: begin
        snapshot = source;
        return rdma_status::success();
      end
      default: begin
      end
    endcase
    if ($cast(source_hostile, source)) begin
      snapshot_hostile =
        rdma_cmq_self_clone_completion_payload::type_id::create(
          "explicit_completion_payload_snapshot"
        );
      snapshot_hostile.value = source_hostile.value;
      if (source_hostile.nested_h != null) begin
        snapshot_hostile.nested_h = rdma_handle::type_id::create(
          "explicit_completion_payload_handle_snapshot"
        );
        snapshot_hostile.nested_h.kind = source_hostile.nested_h.kind;
        snapshot_hostile.nested_h.function_uid =
          source_hostile.nested_h.function_uid;
        snapshot_hostile.nested_h.object_id = source_hostile.nested_h.object_id;
        snapshot_hostile.nested_h.generation =
          source_hostile.nested_h.generation;
      end
      case (completion_payload_hook_fault)
        RDMA_CMQ_TEST_HOOK_MUTATED_OUTPUT: snapshot_hostile.value++;
        RDMA_CMQ_TEST_HOOK_ALIASED_OUTPUT:
          snapshot_hostile.nested_h = source_hostile.nested_h;
        RDMA_CMQ_TEST_HOOK_MUTATE_SOURCE: source_hostile.value++;
        default: begin
        end
      endcase
      snapshot = snapshot_hostile;
      return rdma_status::success();
    end
    if ($cast(source_xtr, source)) begin
      snapshot_xtr = rdma_hw_cmq_completion::type_id::create(
        "explicit_xtr_completion_payload_snapshot"
      );
      snapshot_xtr.owner = source_xtr.owner;
      snapshot_xtr.opcode = source_xtr.opcode;
      snapshot_xtr.command_ecode = source_xtr.command_ecode;
      snapshot_xtr.wqe_index = source_xtr.wqe_index;
      snapshot_xtr.wrap = source_xtr.wrap;
      snapshot_xtr.object_payload = source_xtr.object_payload;
      case (completion_payload_hook_fault)
        RDMA_CMQ_TEST_HOOK_MUTATED_OUTPUT: snapshot_xtr.opcode++;
        RDMA_CMQ_TEST_HOOK_MUTATE_SOURCE: source_xtr.opcode++;
        default: begin
        end
      endcase
      snapshot = snapshot_xtr;
      return rdma_status::success();
    end
    return rdma_status::make(
      RDMA_SC_INVALID_ARGUMENT,
      "test profile completion payload type is unsupported"
    );
  endfunction

  // 功能：在 rdma_cmq_test_profile 中由 same_completion_payload_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_completion_payload_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  virtual function bit same_completion_payload_value(
    uvm_object lhs,
    uvm_object rhs
  );
    rdma_cmq_self_clone_completion_payload lhs_hostile;
    rdma_cmq_self_clone_completion_payload rhs_hostile;
    rdma_hw_cmq_completion lhs_xtr;
    rdma_hw_cmq_completion rhs_xtr;

    completion_payload_same_calls++;
    if (completion_payload_hook_fault ==
          RDMA_CMQ_TEST_HOOK_STATEFUL_SAME_DRIFT &&
        completion_payload_same_calls > 1)
      return 1'b0;
    if ($cast(lhs_hostile, lhs) && $cast(rhs_hostile, rhs)) begin
      if (lhs_hostile.nested_h == null || rhs_hostile.nested_h == null)
        return 1'b0;
      return lhs_hostile.value == rhs_hostile.value &&
             lhs_hostile.nested_h.same_instance(rhs_hostile.nested_h);
    end
    if ($cast(lhs_xtr, lhs) && $cast(rhs_xtr, rhs)) begin
      if (lhs_xtr.object_payload.size() != rhs_xtr.object_payload.size())
        return 1'b0;
      foreach (lhs_xtr.object_payload[i])
        if (lhs_xtr.object_payload[i] != rhs_xtr.object_payload[i])
          return 1'b0;
      return lhs_xtr.owner == rhs_xtr.owner &&
             lhs_xtr.opcode == rhs_xtr.opcode &&
             lhs_xtr.command_ecode == rhs_xtr.command_ecode &&
             lhs_xtr.wqe_index == rhs_xtr.wqe_index &&
             lhs_xtr.wrap == rhs_xtr.wrap;
    end
    return 1'b0;
  endfunction

  // 功能：在 rdma_cmq_test_profile 中，completion_payload_graph_detached 检查嵌套 body/graph 引用是否已经 detached，防止编码或恢复阶段残留可变别名。
  // 输入/输出及副作用：source（输入）、snapshot（输入）；completion_payload_graph_detached 读取 source、snapshot 并使用字段 completion_payload_hook_fault、completion_payload_detach_calls；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：completion_payload_graph_detached 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  virtual function bit completion_payload_graph_detached(
    uvm_object source,
    uvm_object snapshot
  );
    rdma_cmq_self_clone_completion_payload source_hostile;
    rdma_cmq_self_clone_completion_payload snapshot_hostile;
    rdma_hw_cmq_completion source_xtr;
    rdma_hw_cmq_completion snapshot_xtr;

    completion_payload_detach_calls++;
    if (completion_payload_hook_fault ==
          RDMA_CMQ_TEST_HOOK_STATEFUL_DETACH_DRIFT &&
        completion_payload_detach_calls > 1)
      return 1'b0;
    if ($cast(source_hostile, source) &&
        $cast(snapshot_hostile, snapshot))
      return source_hostile != snapshot_hostile &&
             source_hostile.nested_h != null &&
             snapshot_hostile.nested_h != null &&
             source_hostile.nested_h != snapshot_hostile.nested_h;
    if ($cast(source_xtr, source) && $cast(snapshot_xtr, snapshot))
      return source_xtr != snapshot_xtr;
    return 1'b0;
  endfunction

  // 功能：在 rdma_cmq_test_profile 中，encode_doorbell 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：cmq_h（输入）、final_pi（输入）、polarity（输入）、image（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_doorbell 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  virtual function rdma_status encode_doorbell(
    rdma_handle cmq_h,
    int unsigned final_pi,
    bit polarity,
    output rdma_hw_image image
  );
    byte unsigned payload[8];
    rdma_cmq_clone_fault_image clone_fault_image;

    image = null;
    doorbell_calls++;
    last_final_pi = final_pi;
    last_polarity = polarity;
    last_doorbell_input = cmq_h;
    last_doorbell_target = rdma_clone_handle_value(
      cmq_h, "test profile doorbell target"
    );
    if (doorbell_input_fault != RDMA_CMQ_TEST_DB_INPUT_GOOD) begin
      cmq_h.object_id++;
      case (doorbell_input_fault)
        RDMA_CMQ_TEST_DB_INPUT_MUTATE_FAILURE:
          return rdma_status::make(
            RDMA_SC_CODEC_ERROR,
            "injected mutating doorbell encode failure"
          );
        RDMA_CMQ_TEST_DB_INPUT_MUTATE_NULL: return null;
        default: begin
        end
      endcase
    end
    if (fail_doorbell_encode)
      return rdma_status::make(doorbell_failure_code,
                               "injected doorbell encode failure");
    if (doorbell_fault == RDMA_CMQ_TEST_DB_NULL)
      return rdma_status::success();
    payload = '{byte'(final_pi), byte'(polarity),
                byte'(cmq_h.object_id[7:0]),
                byte'(cmq_h.object_id[15:8]),
                8'ha5, 8'h5a, 8'hc3, 8'h3c};
    image = rdma_hw_image::type_id::create("test_doorbell");
    foreach (payload[i]) image.bytes.push_back(payload[i]);
    image.length = $size(payload);
    image.alignment = 8;
    image.endian = RDMA_ENDIAN_LITTLE;
    image.image_kind = RDMA_IMAGE_DOORBELL;
    image.hardware_version = 9;
    image.function_generation = cmq_h.generation;
    image.write_target_kind = RDMA_HW_TARGET_BAR;
    image.bar_target.value = TEST_DOORBELL_OFFSET;
    case (doorbell_fault)
      RDMA_CMQ_TEST_DB_BAD_LENGTH: image.length = 7;
      RDMA_CMQ_TEST_DB_BAD_KIND: image.image_kind = RDMA_IMAGE_CMQ_SQE;
      RDMA_CMQ_TEST_DB_STALE_GENERATION:
        image.function_generation++;
      RDMA_CMQ_TEST_DB_BAD_TARGET_KIND:
        image.write_target_kind = RDMA_HW_TARGET_BACKING;
      RDMA_CMQ_TEST_DB_INACTIVE_BACKING:
        image.backing_target.value = 64'h40;
      RDMA_CMQ_TEST_DB_INACTIVE_HMC:
        image.hmc_target.value = 64'h80;
      RDMA_CMQ_TEST_DB_CLONE_SELF,
      RDMA_CMQ_TEST_DB_CLONE_MUTATE: begin
        clone_fault_image = rdma_cmq_clone_fault_image::type_id::create(
          "test_doorbell_clone_fault"
        );
        clone_fault_image.copy(image);
        clone_fault_image.clone_fault =
          (doorbell_fault == RDMA_CMQ_TEST_DB_CLONE_SELF) ?
            RDMA_CMQ_TEST_CLONE_SELF : RDMA_CMQ_TEST_CLONE_MUTATE;
        image = clone_fault_image;
      end
      default: begin
      end
    endcase
    return rdma_status::success();
  endfunction
endclass

class rdma_cmq_profile_hook_fault_profile extends rdma_cmq_test_profile;
  `uvm_object_utils(rdma_cmq_profile_hook_fault_profile)

  rdma_cmq_test_hook_fault_e snapshot_fault;
  rdma_cmq_test_extension_fault_e extension_fault;
  rdma_cmq_test_direct_handle_fault_e direct_handle_fault;
  int unsigned snapshot_calls;
  int unsigned same_calls;
  int unsigned detach_calls;

  // 功能：构造 rdma_cmq_profile_hook_fault_profile，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：snapshot_fault=RDMA_CMQ_TEST_HOOK_GOOD；extension_fault=RDMA_CMQ_TEST_EXTENSION_GOOD；direct_handle_fault=RDMA_CMQ_TEST_DIRECT_HANDLE_GOOD；snapshot_calls=0；same_calls=0；detach_calls=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_profile_hook_fault_profile 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_profile_hook_fault_profile");
    super.new(name);
    snapshot_fault = RDMA_CMQ_TEST_HOOK_GOOD;
    extension_fault = RDMA_CMQ_TEST_EXTENSION_GOOD;
    direct_handle_fault = RDMA_CMQ_TEST_DIRECT_HANDLE_GOOD;
    snapshot_calls = 0;
    same_calls = 0;
    detach_calls = 0;
  endfunction

  // 功能：copy_nested_handle 复制 source 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）；copy_nested_handle 读取 source 并使用字段 result、result.kind、result.function_uid、result.object_id、result.generation；函数返回 rdma_handle，不取得调用方资源所有权。
  // 失败/边界：输入为空、类型不匹配或字段组合非法时返回空值/错误；不得发布不完整快照。
  protected function rdma_handle copy_nested_handle(rdma_handle source);
    rdma_handle result;

    if (source == null)
      return null;
    result = rdma_handle::type_id::create("hook_snapshot_handle");
    result.kind = source.kind;
    result.function_uid = source.function_uid;
    result.object_id = source.object_id;
    result.generation = source.generation;
    return result;
  endfunction

  // 功能：copy_function_handle 复制 source 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）；copy_function_handle 读取 source 并使用字段 result、result.kind、result.function_uid、result.object_id、result.generation；函数返回 rdma_function_handle，不取得调用方资源所有权。
  // 失败/边界：输入为空、类型不匹配或字段组合非法时返回空值/错误；不得发布不完整快照。
  protected function rdma_function_handle copy_function_handle(
    rdma_function_handle source
  );
    rdma_function_handle result;

    if (source == null)
      return null;
    result = rdma_function_handle::type_id::create(
      "hook_snapshot_function_handle"
    );
    result.kind = source.kind;
    result.function_uid = source.function_uid;
    result.object_id = source.object_id;
    result.generation = source.generation;
    return result;
  endfunction

  // 功能：在 rdma_cmq_profile_hook_fault_profile 中由 same_nested_handle_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_nested_handle_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_nested_handle_value(
    rdma_handle lhs,
    rdma_handle rhs
  );
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    return lhs.kind == rhs.kind &&
           lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id &&
           lhs.generation == rhs.generation;
  endfunction

  // 功能：在 rdma_cmq_profile_hook_fault_profile 中由 same_sqe_base_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_sqe_base_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_sqe_base_value(
    rdma_cmq_sqe_model lhs,
    rdma_cmq_sqe_model rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.opcode == rhs.opcode &&
           lhs.command_id == rhs.command_id &&
           lhs.flags == rhs.flags &&
           same_nested_handle_value(lhs.function_h, rhs.function_h) &&
           same_nested_handle_value(lhs.target_h, rhs.target_h) &&
           lhs.context_model == null && rhs.context_model == null;
  endfunction

  // 功能：在 rdma_cmq_profile_hook_fault_profile 中，append_sqe_graph_nodes 将输入对象登记或挂接到当前集合/依赖图，并同步维护对应账本和生命周期引用。
  // 输入/输出及副作用：sqe（输入）、extension_edge（输入）、nodes（引用）；append_sqe_graph_nodes 可能更新本对象明确拥有的状态，并写入 nodes；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：append_sqe_graph_nodes 无返回值，仅执行 函数体中的顺序操作；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  protected function void append_sqe_graph_nodes(
    rdma_cmq_sqe_model sqe,
    uvm_object extension_edge,
    ref uvm_object nodes[$]
  );
    if (sqe == null)
      return;
    nodes.push_back(sqe);
    if (sqe.function_h != null) nodes.push_back(sqe.function_h);
    if (sqe.target_h != null) nodes.push_back(sqe.target_h);
    if (sqe.context_model != null) nodes.push_back(sqe.context_model);
    if (extension_edge != null) nodes.push_back(extension_edge);
  endfunction

  // 功能：在 rdma_cmq_profile_hook_fault_profile 中，sqe_graphs_are_detached 检查嵌套 body/graph 引用是否已经 detached，防止编码或恢复阶段残留可变别名。
  // 输入/输出及副作用：source（输入）、source_extension_edge（输入）、snapshot（输入）、snapshot_extension_edge（输入）；sqe_graphs_are_detached 读取 source、source_extension_edge、snapshot、snapshot_extension_edge 并使用字段 source_nodes、snapshot_nodes、j；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：sqe_graphs_are_detached 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function bit sqe_graphs_are_detached(
    rdma_cmq_sqe_model source,
    uvm_object source_extension_edge,
    rdma_cmq_sqe_model snapshot,
    uvm_object snapshot_extension_edge
  );
    uvm_object source_nodes[$];
    uvm_object snapshot_nodes[$];

    append_sqe_graph_nodes(source, source_extension_edge, source_nodes);
    append_sqe_graph_nodes(snapshot, snapshot_extension_edge,
                           snapshot_nodes);
    foreach (source_nodes[i])
      foreach (snapshot_nodes[j])
        if (source_nodes[i] == snapshot_nodes[j])
          return 1'b0;
    return source_nodes.size() != 0 && snapshot_nodes.size() != 0;
  endfunction

  // 功能：在 rdma_cmq_profile_hook_fault_profile 中由 same_qpc_base_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_qpc_base_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_qpc_base_value(
    rdma_qpc_model lhs,
    rdma_qpc_model rhs
  );
    if (lhs == null || rhs == null ||
        lhs.address_vector == null || rhs.address_vector == null ||
        lhs.behavior == null || rhs.behavior == null ||
        lhs.transport_ext == null || rhs.transport_ext == null)
      return 1'b0;
    return same_nested_handle_value(lhs.qp_h, rhs.qp_h) &&
           same_nested_handle_value(lhs.pd_h, rhs.pd_h) &&
           same_nested_handle_value(lhs.send_cq_h, rhs.send_cq_h) &&
           same_nested_handle_value(lhs.recv_cq_h, rhs.recv_cq_h) &&
           same_nested_handle_value(lhs.srq_h, rhs.srq_h) &&
           lhs.transport == rhs.transport && lhs.state == rhs.state &&
           lhs.host_id == rhs.host_id && lhs.vf_id == rhs.vf_id &&
           lhs.stat_index == rhs.stat_index && lhs.pkey == rhs.pkey &&
           lhs.qp_sequence == rhs.qp_sequence &&
           lhs.access == rhs.access &&
           lhs.path_mtu_bytes == rhs.path_mtu_bytes &&
           lhs.sq_depth == rhs.sq_depth && lhs.rq_depth == rhs.rq_depth &&
           lhs.sq_backing.value == rhs.sq_backing.value &&
           lhs.rq_backing.value == rhs.rq_backing.value &&
           lhs.context_backing.value == rhs.context_backing.value &&
           lhs.sq_mode == rhs.sq_mode && lhs.rq_mode == rhs.rq_mode &&
           lhs.signature_enable == rhs.signature_enable &&
           lhs.tx_flow_control == rhs.tx_flow_control &&
           lhs.rx_flow_control == rhs.rx_flow_control &&
           lhs.address_vector.describe() == rhs.address_vector.describe() &&
           lhs.behavior.describe() == rhs.behavior.describe() &&
           lhs.transport_ext.get_type_name() ==
             rhs.transport_ext.get_type_name() &&
           lhs.transport_ext.describe() == rhs.transport_ext.describe();
  endfunction

  // 功能：在 rdma_cmq_profile_hook_fault_profile 中，append_qpc_graph_nodes 将输入对象登记或挂接到当前集合/依赖图，并同步维护对应账本和生命周期引用。
  // 输入/输出及副作用：qpc（输入）、extension_edge（输入）、nodes（引用）；append_qpc_graph_nodes 可能更新本对象明确拥有的状态，并写入 nodes；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：append_qpc_graph_nodes 无返回值，仅执行 函数体中的顺序操作；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  protected function void append_qpc_graph_nodes(
    rdma_qpc_model qpc,
    uvm_object extension_edge,
    ref uvm_object nodes[$]
  );
    rdma_qpc_urc_ext urc_ext;

    if (qpc == null)
      return;
    nodes.push_back(qpc);
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
    if (extension_edge != null) nodes.push_back(extension_edge);
  endfunction

  // 功能：在 rdma_cmq_profile_hook_fault_profile 中，qpc_graphs_are_detached 检查嵌套 body/graph 引用是否已经 detached，防止编码或恢复阶段残留可变别名。
  // 输入/输出及副作用：source（输入）、source_extension_edge（输入）、snapshot（输入）、snapshot_extension_edge（输入）；qpc_graphs_are_detached 读取 source、source_extension_edge、snapshot、snapshot_extension_edge 并使用字段 source_nodes、snapshot_nodes、j；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：qpc_graphs_are_detached 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  protected function bit qpc_graphs_are_detached(
    rdma_qpc_model source,
    uvm_object source_extension_edge,
    rdma_qpc_model snapshot,
    uvm_object snapshot_extension_edge
  );
    uvm_object source_nodes[$];
    uvm_object snapshot_nodes[$];

    append_qpc_graph_nodes(source, source_extension_edge, source_nodes);
    append_qpc_graph_nodes(snapshot, snapshot_extension_edge, snapshot_nodes);
    foreach (source_nodes[i])
      foreach (snapshot_nodes[j])
        if (source_nodes[i] == snapshot_nodes[j])
          return 1'b0;
    return source_nodes.size() != 0 && snapshot_nodes.size() != 0;
  endfunction

  // 功能：在 rdma_cmq_profile_hook_fault_profile 中，snapshot_command_body 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：source（输入）、snapshot（输出）；snapshot_command_body 读取 source、snapshot 并使用字段 snapshot、snapshot_sqe、snapshot_sqe.opcode、snapshot_sqe.command_id、snapshot_sqe.flags、snapshot_scalar_handle、snapshot_scalar_handle.kind、snapshot_scalar_handle.function_uid，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：snapshot_command_body 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  virtual function rdma_status snapshot_command_body(
    rdma_hw_model source,
    output rdma_hw_model snapshot
  );
    rdma_cmq_profile_hook_body source_body;
    rdma_cmq_profile_hook_body snapshot_body;
    rdma_cmq_scalar_extension_qpc source_scalar;
    rdma_cmq_scalar_extension_qpc snapshot_scalar;
    rdma_cmq_edge_extension_qpc source_edge;
    rdma_cmq_edge_extension_qpc snapshot_edge;
    rdma_cmq_sqe_model source_sqe;
    rdma_cmq_sqe_model snapshot_sqe;
    rdma_cmq_scalar_extension_function_handle source_scalar_handle;
    rdma_cmq_scalar_extension_function_handle snapshot_scalar_handle;
    rdma_cmq_edge_extension_handle source_edge_handle;
    rdma_cmq_edge_extension_handle snapshot_edge_handle;
    uvm_object cloned_object;

    snapshot = null;
    if ($cast(source_sqe, source) &&
        ($cast(source_scalar_handle, source_sqe.function_h) ||
         $cast(source_edge_handle, source_sqe.target_h))) begin
      snapshot_calls++;
      snapshot_sqe = rdma_cmq_sqe_model::type_id::create(
        "profile_direct_handle_sqe_snapshot"
      );
      snapshot_sqe.opcode = source_sqe.opcode;
      snapshot_sqe.command_id = source_sqe.command_id;
      snapshot_sqe.flags = source_sqe.flags;
      if (source_scalar_handle != null) begin
        snapshot_scalar_handle =
          rdma_cmq_scalar_extension_function_handle::type_id::create(
            "profile_scalar_function_snapshot"
          );
        snapshot_scalar_handle.kind = source_scalar_handle.kind;
        snapshot_scalar_handle.function_uid =
          source_scalar_handle.function_uid;
        snapshot_scalar_handle.object_id = source_scalar_handle.object_id;
        snapshot_scalar_handle.generation = source_scalar_handle.generation;
        snapshot_scalar_handle.extension_value =
          source_scalar_handle.extension_value;
        if (direct_handle_fault == RDMA_CMQ_TEST_DIRECT_HANDLE_DROP_SCALAR)
          snapshot_scalar_handle.extension_value = 0;
        snapshot_sqe.function_h = snapshot_scalar_handle;
      end
      else begin
        snapshot_sqe.function_h = copy_function_handle(
          source_sqe.function_h
        );
      end
      if (source_edge_handle != null) begin
        snapshot_edge_handle =
          rdma_cmq_edge_extension_handle::type_id::create(
            "profile_edge_target_snapshot"
          );
        snapshot_edge_handle.kind = source_edge_handle.kind;
        snapshot_edge_handle.function_uid = source_edge_handle.function_uid;
        snapshot_edge_handle.object_id = source_edge_handle.object_id;
        snapshot_edge_handle.generation = source_edge_handle.generation;
        snapshot_edge_handle.extension_h = copy_nested_handle(
          source_edge_handle.extension_h
        );
        if (direct_handle_fault == RDMA_CMQ_TEST_DIRECT_HANDLE_ALIAS_EDGE)
          snapshot_edge_handle.extension_h = source_edge_handle.extension_h;
        snapshot_sqe.target_h = snapshot_edge_handle;
      end
      else begin
        snapshot_sqe.target_h = copy_nested_handle(source_sqe.target_h);
      end
      snapshot_sqe.context_model = null;
      snapshot = snapshot_sqe;
      return rdma_status::success();
    end
    if ($cast(source_scalar, source)) begin
      snapshot_calls++;
      if (extension_fault == RDMA_CMQ_TEST_EXTENSION_NULL_OUTPUT)
        return rdma_status::success();
      snapshot_scalar = rdma_cmq_scalar_extension_qpc::type_id::create(
        "profile_scalar_extension_snapshot"
      );
      snapshot_scalar.copy(source_scalar);
      snapshot_scalar.extension_value = source_scalar.extension_value;
      case (extension_fault)
        RDMA_CMQ_TEST_EXTENSION_DROP_SCALAR:
          snapshot_scalar.extension_value = 0;
        RDMA_CMQ_TEST_EXTENSION_MUTATE_SOURCE:
          source_scalar.extension_value++;
        default: begin
        end
      endcase
      snapshot = snapshot_scalar;
      return rdma_status::success();
    end
    if ($cast(source_edge, source)) begin
      snapshot_calls++;
      if (extension_fault == RDMA_CMQ_TEST_EXTENSION_NULL_OUTPUT)
        return rdma_status::success();
      snapshot_edge = rdma_cmq_edge_extension_qpc::type_id::create(
        "profile_edge_extension_snapshot"
      );
      snapshot_edge.copy(source_edge);
      snapshot_edge.extension_h = copy_nested_handle(source_edge.extension_h);
      if (extension_fault == RDMA_CMQ_TEST_EXTENSION_ALIAS_EDGE)
        snapshot_edge.extension_h = source_edge.extension_h;
      snapshot = snapshot_edge;
      return rdma_status::success();
    end
    if (!$cast(source_body, source))
      return super.snapshot_command_body(source, snapshot);
    snapshot_calls++;
    if (snapshot_fault inside {
          RDMA_CMQ_TEST_HOOK_STATEFUL_SAME_DRIFT,
          RDMA_CMQ_TEST_HOOK_STATEFUL_DETACH_DRIFT
        }) begin
      cloned_object = source.clone();
      if (cloned_object == null || !$cast(snapshot_body, cloned_object) ||
          snapshot_body == source_body) begin
        snapshot = null;
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "injected stateful custom body preflight clone failed"
        );
      end
      snapshot = snapshot_body;
      return rdma_status::success();
    end
    case (snapshot_fault)
      RDMA_CMQ_TEST_HOOK_NULL_STATUS:
        return null;
      RDMA_CMQ_TEST_HOOK_NONOK_STATUS:
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "injected ordinary custom body snapshot rejection"
        );
      RDMA_CMQ_TEST_HOOK_NULL_OUTPUT:
        return rdma_status::success();
      RDMA_CMQ_TEST_HOOK_WRONG_TYPE: begin
        snapshot = rdma_cmq_unknown_body::type_id::create(
          "hook_wrong_type_output"
        );
        return rdma_status::success();
      end
      RDMA_CMQ_TEST_HOOK_SELF_OUTPUT: begin
        snapshot = source;
        return rdma_status::success();
      end
      default: begin
        snapshot_body = rdma_cmq_profile_hook_body::type_id::create(
          "hook_snapshot_output"
        );
        snapshot_body.value = source_body.value;
        snapshot_body.nested_h = copy_nested_handle(source_body.nested_h);
        case (snapshot_fault)
          RDMA_CMQ_TEST_HOOK_MUTATED_OUTPUT:
            snapshot_body.value++;
          RDMA_CMQ_TEST_HOOK_ALIASED_OUTPUT:
            snapshot_body.nested_h = source_body.nested_h;
          RDMA_CMQ_TEST_HOOK_NULL_VALIDATION:
            snapshot_body.validation_returns_null = 1'b1;
          RDMA_CMQ_TEST_HOOK_FAILED_VALIDATION:
            snapshot_body.validation_fails = 1'b1;
          default: begin
          end
        endcase
        snapshot = snapshot_body;
        return rdma_status::success();
      end
    endcase
  endfunction

  // 功能：在 rdma_cmq_profile_hook_fault_profile 中由 same_command_body_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_command_body_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  virtual function bit same_command_body_value(
    rdma_hw_model lhs,
    rdma_hw_model rhs
  );
    rdma_cmq_profile_hook_body lhs_body;
    rdma_cmq_profile_hook_body rhs_body;
    rdma_cmq_scalar_extension_qpc lhs_scalar;
    rdma_cmq_scalar_extension_qpc rhs_scalar;
    rdma_cmq_edge_extension_qpc lhs_edge;
    rdma_cmq_edge_extension_qpc rhs_edge;
    rdma_cmq_sqe_model lhs_sqe;
    rdma_cmq_sqe_model rhs_sqe;
    rdma_cmq_scalar_extension_function_handle lhs_scalar_handle;
    rdma_cmq_scalar_extension_function_handle rhs_scalar_handle;
    rdma_cmq_edge_extension_handle lhs_edge_handle;
    rdma_cmq_edge_extension_handle rhs_edge_handle;
    bit same_value;

    if ($cast(lhs_sqe, lhs) && $cast(rhs_sqe, rhs)) begin
      if ($cast(lhs_scalar_handle, lhs_sqe.function_h) &&
          $cast(rhs_scalar_handle, rhs_sqe.function_h)) begin
        same_calls++;
        same_value = same_sqe_base_value(lhs_sqe, rhs_sqe) &&
                     lhs_scalar_handle.extension_value ==
                       rhs_scalar_handle.extension_value;
        if (direct_handle_fault ==
              RDMA_CMQ_TEST_DIRECT_HANDLE_DROP_SCALAR &&
            same_calls == 1)
          return same_sqe_base_value(lhs_sqe, rhs_sqe);
        if (direct_handle_fault ==
              RDMA_CMQ_TEST_DIRECT_HANDLE_SAME_DRIFT &&
            same_calls > 1)
          return 1'b0;
        return same_value;
      end
      if ($cast(lhs_edge_handle, lhs_sqe.target_h) &&
          $cast(rhs_edge_handle, rhs_sqe.target_h)) begin
        same_calls++;
        same_value = same_sqe_base_value(lhs_sqe, rhs_sqe) &&
                     same_nested_handle_value(
                       lhs_edge_handle.extension_h,
                       rhs_edge_handle.extension_h
                     );
        return same_value;
      end
    end
    if ($cast(lhs_scalar, lhs) && $cast(rhs_scalar, rhs)) begin
      same_calls++;
      return same_qpc_base_value(lhs_scalar, rhs_scalar) &&
             lhs_scalar.extension_value == rhs_scalar.extension_value;
    end
    if ($cast(lhs_edge, lhs) && $cast(rhs_edge, rhs)) begin
      same_calls++;
      return same_qpc_base_value(lhs_edge, rhs_edge) &&
             same_nested_handle_value(lhs_edge.extension_h,
                                      rhs_edge.extension_h);
    end
    if (!$cast(lhs_body, lhs) || !$cast(rhs_body, rhs) ||
        lhs_body.nested_h == null || rhs_body.nested_h == null)
      return 1'b0;
    same_calls++;
    same_value = lhs_body.value == rhs_body.value &&
                 lhs_body.nested_h.kind == rhs_body.nested_h.kind &&
                 lhs_body.nested_h.function_uid ==
                   rhs_body.nested_h.function_uid &&
                 lhs_body.nested_h.object_id == rhs_body.nested_h.object_id &&
                 lhs_body.nested_h.generation == rhs_body.nested_h.generation;
    if (snapshot_fault == RDMA_CMQ_TEST_HOOK_STATEFUL_SAME_DRIFT &&
        same_calls > 1)
      return 1'b0;
    return same_value;
  endfunction

  // 功能：在 rdma_cmq_profile_hook_fault_profile 中，command_body_graph_detached 检查嵌套 body/graph 引用是否已经 detached，防止编码或恢复阶段残留可变别名。
  // 输入/输出及副作用：source（输入）、snapshot（输入）；command_body_graph_detached 读取 source、snapshot 并使用字段 detac；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：command_body_graph_detached 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  virtual function bit command_body_graph_detached(
    rdma_hw_model source,
    rdma_hw_model snapshot
  );
    rdma_cmq_profile_hook_body source_body;
    rdma_cmq_profile_hook_body snapshot_body;
    rdma_cmq_scalar_extension_qpc source_scalar;
    rdma_cmq_scalar_extension_qpc snapshot_scalar;
    rdma_cmq_edge_extension_qpc source_edge;
    rdma_cmq_edge_extension_qpc snapshot_edge;
    rdma_cmq_sqe_model source_sqe;
    rdma_cmq_sqe_model snapshot_sqe;
    rdma_cmq_scalar_extension_function_handle source_scalar_handle;
    rdma_cmq_scalar_extension_function_handle snapshot_scalar_handle;
    rdma_cmq_edge_extension_handle source_edge_handle;
    rdma_cmq_edge_extension_handle snapshot_edge_handle;
    bit detached;

    if ($cast(source_sqe, source) && $cast(snapshot_sqe, snapshot)) begin
      if ($cast(source_scalar_handle, source_sqe.function_h) &&
          $cast(snapshot_scalar_handle, snapshot_sqe.function_h)) begin
        detach_calls++;
        detached = sqe_graphs_are_detached(source_sqe, null,
                                           snapshot_sqe, null);
        if (direct_handle_fault ==
              RDMA_CMQ_TEST_DIRECT_HANDLE_DETACH_DRIFT &&
            detach_calls > 1)
          return 1'b0;
        return detached;
      end
      if ($cast(source_edge_handle, source_sqe.target_h) &&
          $cast(snapshot_edge_handle, snapshot_sqe.target_h)) begin
        detach_calls++;
        detached = sqe_graphs_are_detached(
          source_sqe, source_edge_handle.extension_h,
          snapshot_sqe, snapshot_edge_handle.extension_h
        );
        if (direct_handle_fault ==
              RDMA_CMQ_TEST_DIRECT_HANDLE_ALIAS_EDGE &&
            detach_calls == 1)
          return 1'b1;
        if (direct_handle_fault ==
              RDMA_CMQ_TEST_DIRECT_HANDLE_DETACH_DRIFT &&
            detach_calls > 1)
          return 1'b0;
        return detached;
      end
    end
    if ($cast(source_scalar, source) &&
        $cast(snapshot_scalar, snapshot)) begin
      detach_calls++;
      return qpc_graphs_are_detached(source_scalar, null,
                                     snapshot_scalar, null);
    end
    if ($cast(source_edge, source) && $cast(snapshot_edge, snapshot)) begin
      detach_calls++;
      return qpc_graphs_are_detached(
        source_edge, source_edge.extension_h,
        snapshot_edge, snapshot_edge.extension_h
      );
    end

    if (!$cast(source_body, source) || !$cast(snapshot_body, snapshot) ||
        source_body == snapshot_body || source_body.nested_h == null ||
        snapshot_body.nested_h == null)
      return 1'b0;
    detach_calls++;
    if (snapshot_fault == RDMA_CMQ_TEST_HOOK_STATEFUL_DETACH_DRIFT &&
        detach_calls > 1)
      return 1'b0;
    return source_body.nested_h != snapshot_body.nested_h;
  endfunction
endclass

class rdma_cmq_test_pcie extends rdma_mock_pcie;
  `uvm_object_utils(rdma_cmq_test_pcie)

  // 功能：构造 rdma_cmq_test_pcie，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_test_pcie 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_test_pcie");
    super.new(name);
  endfunction

  // 功能：在 rdma_cmq_test_pcie 中，dma_visibility_barrier 在截止时间内执行 DMA 可见性或 MMIO 顺序屏障，确保 doorbell 之前的数据写入已按序可见。
  // 输入/输出及副作用：function_h（输入）、status（输出）；dma_visibility_barrier 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：dma_visibility_barrier 失败或超时通过 status 明确发布；该路径不隐式重试，也不转移未声明资源。
  virtual task dma_visibility_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );
    rdma_mock_call_trace saved_trace;

    saved_trace = call_trace;
    call_trace = null;
    void'(record_call("dma_visibility_barrier", '0, '0, '0, '0,
                      function_h));
    call_trace = saved_trace;
    if (call_trace != null)
      call_trace.record("pcie_dma_barrier");
    status = take_failure("dma_visibility_barrier");
    if (status == null)
      status = rdma_status::success();
  endtask

  // 功能：在 rdma_cmq_test_pcie 中，mmio_ordering_barrier 在截止时间内执行 DMA 可见性或 MMIO 顺序屏障，确保 doorbell 之前的数据写入已按序可见。
  // 输入/输出及副作用：function_h（输入）、status（输出）；mmio_ordering_barrier 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：mmio_ordering_barrier 失败或超时通过 status 明确发布；该路径不隐式重试，也不转移未声明资源。
  virtual task mmio_ordering_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );
    rdma_mock_call_trace saved_trace;

    saved_trace = call_trace;
    call_trace = null;
    void'(record_call("mmio_ordering_barrier", '0, '0, '0, '0,
                      function_h));
    call_trace = saved_trace;
    if (call_trace != null)
      call_trace.record("pcie_mmio_barrier");
    status = take_failure("mmio_ordering_barrier");
    if (status == null)
      status = rdma_status::success();
  endtask
endclass

class rdma_cmq_test_blocking_pcie extends rdma_cmq_test_pcie;
  `uvm_object_utils(rdma_cmq_test_blocking_pcie)

  bit block_dma_barrier;
  bit dma_barrier_entered;
  bit release_dma_barrier;

  // 功能：构造 rdma_cmq_test_blocking_pcie，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：block_dma_barrier=1'b0；dma_barrier_entered=1'b0；release_dma_barrier=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_test_blocking_pcie 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_test_blocking_pcie");
    super.new(name);
    block_dma_barrier = 1'b0;
    dma_barrier_entered = 1'b0;
    release_dma_barrier = 1'b0;
  endfunction

  // 功能：在 rdma_cmq_test_blocking_pcie 中，dma_visibility_barrier 在截止时间内执行 DMA 可见性或 MMIO 顺序屏障，确保 doorbell 之前的数据写入已按序可见。
  // 输入/输出及副作用：function_h（输入）、status（输出）；dma_visibility_barrier 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：dma_visibility_barrier 失败或超时通过 status 明确发布；该路径不隐式重试，也不转移未声明资源。
  virtual task dma_visibility_barrier(
    rdma_function_handle function_h,
    output rdma_status status
  );
    rdma_mock_call_trace saved_trace;

    saved_trace = call_trace;
    call_trace = null;
    void'(record_call("dma_visibility_barrier", '0, '0, '0, '0,
                      function_h));
    call_trace = saved_trace;
    if (call_trace != null)
      call_trace.record("pcie_dma_barrier");
    status = take_failure("dma_visibility_barrier");
    if (status != null)
      return;
    if (block_dma_barrier) begin
      dma_barrier_entered = 1'b1;
      wait (release_dma_barrier);
    end
    status = rdma_status::success();
  endtask
endclass

class rdma_cmq_bad_clone_command extends rdma_cmq_command_desc;
  `uvm_object_utils(rdma_cmq_bad_clone_command)

  bit return_wrong_type;
  bit return_self;

  // 功能：构造 rdma_cmq_bad_clone_command，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：return_wrong_type=1'b0；return_self=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_bad_clone_command 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_bad_clone_command");
    super.new(name);
    return_wrong_type = 1'b0;
    return_self = 1'b0;
  endfunction

  // 功能：将 rhs 中 rdma_cmq_bad_clone_command 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：rdma_status、return_wrong_type、return_self 并使用字段 rdma_status、return_wrong_type、return_self；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  virtual function uvm_object clone();
    if (return_wrong_type)
      return rdma_status::success("wrong command clone type");
    if (return_self)
      return this;
    return null;
  endfunction
endclass

class rdma_cmq_runtime_clone_failure_engine extends rdma_cmq_engine;
  `uvm_object_utils(rdma_cmq_runtime_clone_failure_engine)

  // 功能：构造 rdma_cmq_runtime_clone_failure_engine，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_runtime_clone_failure_engine 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_runtime_clone_failure_engine");
    super.new(name);
  endfunction

  // 功能：在 rdma_cmq_runtime_clone_failure_engine 中，publish_runtime_snapshot 提交当前事务阶段并发布 detached 结果，只有成功路径才推进游标或状态。
  // 输入/输出及副作用：source（输入）、snapshot（输出）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过
  //   output 返回结果。
  // 失败/边界：队列未激活、credit 不足、请求身份过期或后端写入失败时返回错误；不得提前推进游标或重复提交。
  virtual function rdma_status publish_runtime_snapshot(
    rdma_cmq_runtime_desc source,
    output rdma_cmq_runtime_desc snapshot
  );
    snapshot = null;
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "injected runtime descriptor clone failure");
  endfunction
endclass

class rdma_cmq_runtime_build_failure_engine extends rdma_cmq_engine;
  `uvm_object_utils(rdma_cmq_runtime_build_failure_engine)

  bit return_null_status;

  // 功能：构造 rdma_cmq_runtime_build_failure_engine，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：return_null_status=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_runtime_build_failure_engine 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_runtime_build_failure_engine");
    super.new(name);
    return_null_status = 1'b0;
  endfunction

  // 功能：build_runtime_desc 创建独立的 rdma_status；根据 request_context、cmq、mapping、runtime 设置字段 runtime，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：request_context（输入）、cmq（输入）、mapping（输入）、runtime（输出）；build_runtime_desc 读取 request_context、cmq、mapping、runtime 并使用字段 runtime，并写入 runtime；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：build_runtime_desc 返回 RDMA_SC_CODEC_ERROR；典型拒绝条件为“injected runtime construction failure”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status build_runtime_desc(
    rdma_dma_request_context request_context,
    rdma_cmq cmq,
    rdma_dma_mapping mapping,
    output rdma_cmq_runtime_desc runtime
  );
    runtime = null;
    if (return_null_status)
      return null;
    return rdma_status::make(RDMA_SC_CODEC_ERROR,
                             "injected runtime construction failure");
  endfunction
endclass

// 设计说明：transport facade 的单元测试只需要观察同步委托身份，不应把
//   Host-memory/PCIe 行为带入该边界；因此 scheduler 替身直接发布调用方预置的
//   call-local result，并记录 binding、descriptor 与 observer 的对象 identity。
class rdma_cmq_transport_scheduler_double extends rdma_doorbell_scheduler;
  `uvm_object_utils(rdma_cmq_transport_scheduler_double)

  int unsigned submit_calls;
  rdma_function_binding last_binding;
  rdma_doorbell_desc last_desc;
  rdma_doorbell_submission_observer last_observer;
  rdma_doorbell_submission_result response;
  bit return_null_result;

  // 功能：构造尚未收到 facade 委托的 scheduler 替身，并清空预置响应与 identity 记录。
  // 输入/输出及副作用：name 传给父类；submit_calls 置零，所有 identity、
  //   response 置空，return_null_result 置零。
  // 失败/边界：构造不配置父类 adapter，也不取得 response/参数所有权；
  //   测试必须在委托前显式设置 response。
  function new(string name = "rdma_cmq_transport_scheduler_double");
    super.new(name);
    submit_calls = 0;
    last_binding = null;
    last_desc = null;
    last_observer = null;
    response = null;
    return_null_result = 1'b0;
  endfunction

  // 功能：记录 transport 透传的三个对象 identity，并按故障开关原样发布 response 或 null。
  // 输入/输出及副作用：binding、desc、observer 为非拥有输入；记录 identity
  //   并将 submit_calls 加一，result 与 response 为同一对象或为 null。
  // 失败/边界：return_null_result 为 1 时故意返回 null；否则即使
  //   response/status 畸形也原样返回，供 facade 修复。
  virtual task submit_observed(
    rdma_function_binding binding,
    rdma_doorbell_desc desc,
    rdma_doorbell_submission_observer observer,
    output rdma_doorbell_submission_result result
  );
    submit_calls++;
    last_binding = binding;
    last_desc = desc;
    last_observer = observer;
    result = return_null_result ? null : response;
  endtask
endclass

// 设计说明：facade 的 observer 契约是 identity 透传；这个无外部依赖的具体实现
//   只为抽象基类提供合法实例，若未来替身错误调用回调，calls 也会留下证据。
class rdma_cmq_transport_observer
  extends rdma_doorbell_submission_observer;

  int unsigned calls;

  // 功能：构造调用计数为零的 transport observer fixture。
  // 输入/输出及副作用：name 传给父类并将 calls 置零；不注册或保存 scheduler。
  // 失败/边界：构造不访问 adapter、不分配外部资源；对象生命周期由当前测试场景管理。
  function new(string name = "rdma_cmq_transport_observer");
    super.new(name);
    calls = 0;
  endfunction

  // 功能：记录一次意外或显式的 MMIO maybe-visible 回调，供测试定位 observer 是否被替换或额外调用。
  // 输入/输出及副作用：无输入和返回值；仅将本对象 calls 加一。
  // 失败/边界：回调不可失败，不等待、不取锁、不调用 adapter 或 scheduler。
  virtual function void before_mmio_maybe_visible();
    calls++;
  endfunction
endclass

typedef enum int unsigned {
  RDMA_CMQ_TAMPER_FUNCTION_KIND,
  RDMA_CMQ_TAMPER_FUNCTION_UID,
  RDMA_CMQ_TAMPER_FUNCTION_OBJECT,
  RDMA_CMQ_TAMPER_FUNCTION_GENERATION,
  RDMA_CMQ_TAMPER_BDF,
  RDMA_CMQ_TAMPER_PASID_VALID,
  RDMA_CMQ_TAMPER_PASID,
  RDMA_CMQ_TAMPER_DMA_DOMAIN_VALID,
  RDMA_CMQ_TAMPER_DMA_DOMAIN,
  RDMA_CMQ_TAMPER_OWNER_NULL,
  RDMA_CMQ_TAMPER_OWNER_KIND,
  RDMA_CMQ_TAMPER_OWNER_UID,
  RDMA_CMQ_TAMPER_OWNER_OBJECT,
  RDMA_CMQ_TAMPER_OWNER_GENERATION,
  RDMA_CMQ_TAMPER_DIRECTION,
  RDMA_CMQ_TAMPER_STATE,
  RDMA_CMQ_TAMPER_SIZE,
  RDMA_CMQ_TAMPER_PERMISSION_READ,
  RDMA_CMQ_TAMPER_PERMISSION_WRITE,
  RDMA_CMQ_TAMPER_IOVA_ALIGNMENT,
  RDMA_CMQ_TAMPER_BACKING_ALIGNMENT,
  RDMA_CMQ_TAMPER_IOVA_RANGE,
  RDMA_CMQ_TAMPER_BACKING_RANGE,
  RDMA_CMQ_TAMPER_PERMISSION_ATOMIC,
  RDMA_CMQ_TAMPER_COUNT
} rdma_cmq_mapping_tamper_e;

class rdma_cmq_engine_probe extends rdma_cmq_engine;
  `uvm_object_utils(rdma_cmq_engine_probe)

  // 功能：构造 rdma_cmq_engine_probe，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_engine_probe 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_engine_probe");
    super.new(name);
  endfunction

  // 功能：返回 engine 构造后冻结的 UVM instance identity，供批次 key 唯一性测试。
  // 输入/输出及副作用：无输入；只读 engine_instance_id 并返回，不修改计数器。
  // 失败/边界：构造契约被破坏时可返回零，测试必须把零视为失败。
  function longint unsigned journal_engine_instance_id();
    return engine_instance_id;
  endfunction

  // 功能：返回成功 prepare 次数形成的当前 engine incarnation。
  // 输入/输出及副作用：无输入；只读 engine_incarnation，不推进 lifecycle。
  // 失败/边界：尚未成功 prepare 时返回零；reset 不应使既有非零值回退。
  function longint unsigned journal_engine_incarnation();
    return engine_incarnation;
  endfunction

  // 功能：返回最近已分配的 batch ID counter，验证 reset 后保持单调。
  // 输入/输出及副作用：无输入；只读 batch_id_counter，不安装 journal 行。
  // 失败/边界：尚未分配 batch 时返回零；该访问器不跳过耗尽值。
  function longint unsigned journal_batch_counter();
    return batch_id_counter;
  endfunction

  // 功能：返回最近已分配的 attempt ID counter，验证失败分配不回绕。
  // 输入/输出及副作用：无输入；只读 attempt_id_counter，不修改 journal。
  // 失败/边界：尚未分配 attempt 时返回零；最大值仍按原值返回。
  function longint unsigned journal_attempt_counter();
    return attempt_id_counter;
  endfunction

  // 功能：返回最近已分配的 reset-proof ID counter，验证其永不复用。
  // 输入/输出及副作用：无输入；只读 reset_proof_id_counter。
  // 失败/边界：尚未分配 proof 时返回零；访问器不隐式创建 proof。
  function longint unsigned journal_reset_proof_counter();
    return reset_proof_id_counter;
  endfunction

  // 功能：为边界测试显式播种四个 journal identity counters。
  // 输入/输出及副作用：incarnation/batch/attempt/proof 为输入；直接覆盖测试 DUT
  //   的受保护计数器，不执行 prepare、I/O 或索引写入。
  // 失败/边界：仅 probe 可调用；允许最大值以覆盖 RESOURCE_EXHAUSTED 分支。
  function void seed_journal_counters(
    longint unsigned incarnation,
    longint unsigned batch_id,
    longint unsigned attempt_id,
    longint unsigned proof_id
  );
    engine_incarnation = incarnation;
    batch_id_counter = batch_id;
    attempt_id_counter = attempt_id;
    reset_proof_id_counter = proof_id;
  endfunction

  // 功能：调用锁内 batch identity allocator，暴露 key/ID 的原子分配结果。
  // 输入/输出及副作用：identity 为只读输入；输出 batch_key/batch_id，成功推进
  //   batch_id_counter；测试串行调用并模拟 engine_lock 已持有。
  // 失败/边界：非法 identity、零 incarnation、counter 溢出或 key 冲突返回错误，
  //   输出清空且 counter 不变。
  function rdma_status allocate_batch_identity_probe(
    rdma_function_identity identity,
    output string batch_key,
    output longint unsigned batch_id
  );
    return allocate_batch_identity_locked(identity, batch_key, batch_id);
  endfunction

  // 功能：调用锁内 attempt allocator，观测单调非零 ID。
  // 输入/输出及副作用：attempt_id 为输出；成功时推进 attempt_id_counter。
  // 失败/边界：counter 已为 64 位最大值时返回 RESOURCE_EXHAUSTED、输出零。
  function rdma_status allocate_attempt_identity_probe(
    output longint unsigned attempt_id
  );
    return allocate_attempt_id_locked(attempt_id);
  endfunction

  // 功能：调用锁内 reset-proof allocator，观测单调非零 proof ID。
  // 输入/输出及副作用：proof_id 为输出；成功推进 reset_proof_id_counter。
  // 失败/边界：counter 已为 64 位最大值时返回 RESOURCE_EXHAUSTED、输出零。
  function rdma_status allocate_reset_proof_identity_probe(
    output longint unsigned proof_id
  );
    return allocate_reset_proof_id_locked(proof_id);
  endfunction

  // 功能：把完整 source record 与 preallocated batch 交给锁内原子安装入口。
  // 输入/输出及副作用：record/preallocated 为非拥有输入；成功安装 detached graph、
  //   ticket index 与 publication value；测试串行调用并模拟已持锁。
  // 失败/边界：digest、cardinality、collision 或 partial value 失败时零行提交。
  function rdma_status install_submission_journal_probe(
    rdma_cmq_batch_submission_record record,
    rdma_cmq_preallocated_publish_batch preallocated
  );
    return install_submission_journal_locked(record, preallocated);
  endfunction

  // 功能：把一个已配置 observer 以 exact handle 登记到 arm capability 表。
  // 输入/输出及副作用：capability_key/observer 为输入；成功写入一行并返回 1。
  // 失败/边界：空 key、null observer 或重复 key 返回 0，不覆盖原 authority。
  function bit register_mmio_arm_observer(
    string capability_key,
    rdma_cmq_mmio_arm_observer observer
  );
    if (capability_key.len() == 0 || observer == null ||
        arm_observers.exists(capability_key))
      return 1'b0;
    arm_observers[capability_key] = observer;
    return 1'b1;
  endfunction

  // 功能：删除指定测试 capability 行，为下一个伪造窗口恢复空表。
  // 输入/输出及副作用：capability_key 为输入；命中时删行并返回 1。
  // 失败/边界：未知 key 返回 0，不修改 journal/preallocation/runtime 账本。
  function bit unregister_mmio_arm_observer(string capability_key);
    if (!arm_observers.exists(capability_key))
      return 1'b0;
    arm_observers.delete(capability_key);
    return 1'b1;
  endfunction

  // 功能：返回当前未消费 arm capability 行数供一次性断言。
  // 输入/输出及副作用：无输入；只读 arm_observers.num() 并返回。
  // 失败/边界：空表返回零，不检查行内 observer 完整性。
  function int unsigned mmio_arm_observer_count();
    return arm_observers.num();
  endfunction

  // 功能：返回 engine-owned 预分配批次的原句柄，供转移 identity 断言。
  // 输入/输出及副作用：batch_key 为输入；命中返回非拥有句柄。
  // 失败/边界：空/未知 key 返回 null，不从 journal 重建预分配值。
  function rdma_cmq_preallocated_publish_batch
  preallocated_publish_fault_reference(string batch_key);
    if (batch_key.len() == 0 ||
        !preallocated_publish_batches.exists(batch_key))
      return null;
    return preallocated_publish_batches[batch_key];
  endfunction

  // 功能：临时取出指定预分配行，注入缺行的 arm 认证窗口。
  // 输入/输出及副作用：batch_key 为输入，命中时通过 value 发布原句柄并删行。
  // 失败/边界：空/未知 key 返回 null 且不触及其他 retained 行。
  function rdma_cmq_preallocated_publish_batch
  take_preallocated_publish_batch(string batch_key);
    rdma_cmq_preallocated_publish_batch value;

    if (batch_key.len() == 0 ||
        !preallocated_publish_batches.exists(batch_key))
      return null;
    value = preallocated_publish_batches[batch_key];
    preallocated_publish_batches.delete(batch_key);
    return value;
  endfunction

  // 功能：把先前取出的 exact 预分配句柄恢复到指定 batch 行。
  // 输入/输出及副作用：batch_key/value 为输入；成功写行并返回 1。
  // 失败/边界：空 key、null value 或已存在行返回 0，不覆盖旧值。
  function bit restore_preallocated_publish_batch(
    string batch_key,
    rdma_cmq_preallocated_publish_batch value
  );
    if (batch_key.len() == 0 || value == null ||
        preallocated_publish_batches.exists(batch_key))
      return 1'b0;
    preallocated_publish_batches[batch_key] = value;
    return 1'b1;
  endfunction

  // 功能：在已持 engine_lock 的同步窗口内调用 observer，暴露任何重入取锁。
  // 输入/输出及副作用：observer 为非拥有输入；task 取锁、同步回调后放锁。
  // 失败/边界：null observer 不解引用；回调若等待或重取锁则本 task 无法完成。
  task call_mmio_arm_while_engine_lock_held(
    rdma_cmq_mmio_arm_observer observer
  );
    engine_lock.get(1);
    if (observer != null)
      observer.before_mmio_maybe_visible();
    engine_lock.put(1);
  endtask

  // 功能：返回当前 runtime producer cursor，供 arm 只推进一次的断言。
  // 输入/输出及副作用：无输入；只读 publish_seq。
  // 失败/边界：counter 损坏时返回原值，不运行 ring invariant 修复。
  function longint unsigned mmio_arm_publish_sequence();
    return publish_seq;
  endfunction

  // 功能：返回指定 slot 的 exact runtime record 句柄供转移断言。
  // 输入/输出及副作用：sq_index 为输入；合法且非空时返回非拥有句柄。
  // 失败/边界：sq_index>=32 或空 slot 返回 null，不创建占位记录。
  function rdma_cmq_slot_record mmio_arm_slot_reference(int unsigned sq_index);
    if (sq_index >= 32)
      return null;
    return slots[sq_index];
  endfunction

  // 功能：查询指定 command token 是否已安装到 runtime 账本。
  // 输入/输出及副作用：token 为输入；合法时返回 token_in_use 位。
  // 失败/边界：token>=32 返回 0，不更改 incarnation 或预留状态。
  function bit mmio_arm_token_in_use(int unsigned token);
    if (token >= 32)
      return 1'b0;
    return token_in_use[token];
  endfunction

  // 功能：按预分配 command key 返回 runtime registry 的 exact slot 句柄。
  // 输入/输出及副作用：key 为输入；命中返回非拥有句柄，只读索引。
  // 失败/边界：未知 key 返回 null，不从 ticket 重算或补写索引。
  function rdma_cmq_slot_record mmio_arm_command_reference(string key);
    if (!command_registry.exists(key))
      return null;
    return command_registry[key];
  endfunction

  // 功能：按预分配 entry key 返回 runtime registry 的 exact slot 句柄。
  // 输入/输出及副作用：key 为输入；命中返回非拥有句柄，只读索引。
  // 失败/边界：未知 key 返回 null，不修改 slot/token 所有权。
  function rdma_cmq_slot_record mmio_arm_entry_reference(string key);
    if (!entry_registry.exists(key))
      return null;
    return entry_registry[key];
  endfunction

  // 功能：把 arm 可写账本投影为稳定文本，供非法回调前后逐值比对。
  // 输入/输出及副作用：batch_key 定位 record；只读 cursor、表基数、
  //   profile 格式与 batch/item mutable evidence 并返回 string。
  // 失败/边界：record/item 缺失时以 missing 标记反映真实损坏，不解引用 null。
  function string mmio_arm_state_fingerprint(string batch_key);
    string value;

    value = $sformatf(
      "p=%016h|s=%0d|t=%0d|c=%0d|e=%0d|j=%0d|a=%0d|o=%0d|f=%0b:%0d:%0d",
      publish_seq, slot_record_count(), tokens_in_use_count(),
      command_registry.num(), entry_registry.num(), submission_journal.num(),
      preallocated_publish_batches.num(), arm_observers.num(),
      profile_image_format_valid, profile_image_endian,
      profile_hardware_version
    );
    if (!submission_journal.exists(batch_key) ||
        submission_journal[batch_key] == null)
      return {value, "|record=missing"};
    value = {value, $sformatf(
      "|b=%0d:%0d:%0d:%0b",
      submission_journal[batch_key].state,
      submission_journal[batch_key].submission_effect,
      submission_journal[batch_key].attempt_effect,
      submission_journal[batch_key].observer_armed
    )};
    foreach (submission_journal[batch_key].items[i]) begin
      if (submission_journal[batch_key].items[i] == null)
        value = {value, "|item=missing"};
      else
        value = {value, $sformatf(
          "|i%0d=%0d:%0d:%0d:%0d:%0b",
          i, submission_journal[batch_key].items[i].state,
          submission_journal[batch_key].items[i].submission_effect,
          submission_journal[batch_key].items[i].attempt_effect,
          submission_journal[batch_key].items[i].completion_phase,
          submission_journal[batch_key].items[i].recovery_required
        )};
    end
    return value;
  endfunction

  // 功能：调用锁内 journal 删除入口，验证 record/index/preallocation 同步移除。
  // 输入/输出及副作用：batch_key 为输入；成功删除该批次的全部 engine-owned 行。
  // 失败/边界：未知 key 或任一索引不一致时返回错误且不删除部分行。
  function rdma_status remove_submission_journal_probe(string batch_key);
    return remove_submission_journal_locked(batch_key);
  endfunction

  // 功能：返回 journal record 行数，供失败原子性断言。
  // 输入/输出及副作用：无输入；只读 submission_journal.num()。
  // 失败/边界：空 journal 返回零；不对行内容做隐式修复。
  function int unsigned submission_journal_count();
    return submission_journal.num();
  endfunction

  // 功能：返回 ticket-to-batch 索引行数，供 cardinality/collision 原子性断言。
  // 输入/输出及副作用：无输入；只读 journal_batch_by_ticket.num()。
  // 失败/边界：索引损坏时仍返回实际行数，完整性由生产 helper 单独检查。
  function int unsigned journal_ticket_index_count();
    return journal_batch_by_ticket.num();
  endfunction

  // 功能：返回 preallocated publication 批次数量，验证三表同时提交。
  // 输入/输出及副作用：无输入；只读 preallocated_publish_batches.num()。
  // 失败/边界：空表返回零；不创建缺失 publication batch。
  function int unsigned preallocated_publish_batch_count();
    return preallocated_publish_batches.num();
  endfunction

  // 功能：返回 batch-to-profile service 行数，验证它与三张 journal 表原子同生同删。
  // 输入/输出及副作用：无输入；只读 journal_profile_by_batch.num()，不调用 profile。
  // 失败/边界：缺行时返回实际数量，不自动从 current profile 或名字重建 authority。
  function int unsigned journal_profile_count();
    return journal_profile_by_batch.num();
  endfunction

  // 功能：确认指定 batch 保存的是 exact expected 非拥有 profile service handle。
  // 输入/输出及副作用：batch_key/expected 为输入；只做句柄 identity 比较。
  // 失败/边界：未知 batch、expected=null 或 map 缺行返回 0，不回退当前 profile。
  function bit journal_profile_matches(
    string batch_key,
    rdma_cmq_hw_profile expected
  );
    return expected != null && journal_profile_by_batch.exists(batch_key) &&
           journal_profile_by_batch[batch_key] == expected;
  endfunction

  // 功能：删除指定 batch 的 profile service 行以注入 retained metadata 损坏。
  // 输入/输出及副作用：batch_key 为输入；命中时仅删除 profile map 行并返回 1。
  // 失败/边界：未知 key 返回 0；不删除 record/index/preallocation，专用于 fail-closed query。
  function bit drop_journal_profile(string batch_key);
    if (!journal_profile_by_batch.exists(batch_key))
      return 1'b0;
    journal_profile_by_batch.delete(batch_key);
    return 1'b1;
  endfunction

  // 功能：恢复指定 batch 的 exact profile service 行，隔离 missing-row 故障窗口。
  // 输入/输出及副作用：batch_key/profile_service 为输入；覆盖该 map 行。
  // 失败/边界：空 key 或 null profile 返回 0 且不写入；不得用于生产 authority 修复。
  function bit restore_journal_profile(
    string batch_key,
    rdma_cmq_hw_profile profile_service
  );
    if (batch_key.len() == 0 || profile_service == null)
      return 1'b0;
    journal_profile_by_batch[batch_key] = profile_service;
    return 1'b1;
  endfunction

  // 功能：返回指定 engine-owned record 的非拥有 fault-injection 引用，供测试逐字段腐化。
  // 输入/输出及副作用：batch_key 为输入；命中时返回 submission_journal 原句柄，
  //   本函数本身不改写 record/index/preallocation/profile。
  // 失败/边界：未知或空 key 返回 null；仅 probe 测试可持有该引用，public query 仍只返回 detached graph。
  function rdma_cmq_batch_submission_record journal_record_fault_reference(
    string batch_key
  );
    if (batch_key.len() == 0 || !submission_journal.exists(batch_key))
      return null;
    return submission_journal[batch_key];
  endfunction

  // 功能：按 kind 向且仅向一张 journal retained 表播种 orphan 行，复现部分提交损坏。
  // 输入/输出及副作用：batch_key 选择目标；record/preallocated/profile_service/ticket
  //   仅由对应 kind 消费；成功写入一行且不触碰其他三张表或 counter。
  // 失败/边界：key 为空、目标依赖无效、该 key 已有任一 companion 或 ticket key
  //   已占用时返回 0；未知 kind 不写入任何状态。
  function bit seed_journal_orphan(
    rdma_cmq_test_journal_orphan_e kind,
    string batch_key,
    rdma_cmq_batch_submission_record record,
    rdma_cmq_preallocated_publish_batch preallocated,
    rdma_cmq_hw_profile profile_service,
    rdma_cmq_ticket ticket
  );
    string ticket_key;

    if (batch_key.len() == 0 || submission_journal.exists(batch_key) ||
        preallocated_publish_batches.exists(batch_key) ||
        journal_profile_by_batch.exists(batch_key))
      return 1'b0;
    case (kind)
      RDMA_CMQ_TEST_JOURNAL_ORPHAN_RECORD: begin
        if (record == null)
          return 1'b0;
        submission_journal[batch_key] = record;
      end
      RDMA_CMQ_TEST_JOURNAL_ORPHAN_PREALLOCATION: begin
        if (preallocated == null)
          return 1'b0;
        preallocated_publish_batches[batch_key] = preallocated;
      end
      RDMA_CMQ_TEST_JOURNAL_ORPHAN_PROFILE: begin
        if (profile_service == null)
          return 1'b0;
        journal_profile_by_batch[batch_key] = profile_service;
      end
      RDMA_CMQ_TEST_JOURNAL_ORPHAN_TICKET_INDEX: begin
        if (!rdma_cmq_ticket_shape_valid(ticket))
          return 1'b0;
        ticket_key = command_key(ticket);
        if (ticket_key.len() == 0 ||
            journal_batch_by_ticket.exists(ticket_key))
          return 1'b0;
        journal_batch_by_ticket[ticket_key] = batch_key;
      end
      default: return 1'b0;
    endcase
    return 1'b1;
  endfunction

  // 功能：删除 seed_journal_orphan() 为指定 kind 创建的唯一 orphan 行，隔离下一故障窗口。
  // 输入/输出及副作用：batch_key/ticket 定位目标；成功只删除对应 record、
  //   preallocation、profile 或 ticket-index 行，不修复或删除任何 companion。
  // 失败/边界：目标行缺失、ticket shape/key 无效、index 指向其他 batch 或未知 kind
  //   时返回 0 且表内容不变。
  function bit clear_journal_orphan(
    rdma_cmq_test_journal_orphan_e kind,
    string batch_key,
    rdma_cmq_ticket ticket
  );
    string ticket_key;

    case (kind)
      RDMA_CMQ_TEST_JOURNAL_ORPHAN_RECORD: begin
        if (!submission_journal.exists(batch_key))
          return 1'b0;
        submission_journal.delete(batch_key);
      end
      RDMA_CMQ_TEST_JOURNAL_ORPHAN_PREALLOCATION: begin
        if (!preallocated_publish_batches.exists(batch_key))
          return 1'b0;
        preallocated_publish_batches.delete(batch_key);
      end
      RDMA_CMQ_TEST_JOURNAL_ORPHAN_PROFILE: begin
        if (!journal_profile_by_batch.exists(batch_key))
          return 1'b0;
        journal_profile_by_batch.delete(batch_key);
      end
      RDMA_CMQ_TEST_JOURNAL_ORPHAN_TICKET_INDEX: begin
        if (!rdma_cmq_ticket_shape_valid(ticket))
          return 1'b0;
        ticket_key = command_key(ticket);
        if (!journal_batch_by_ticket.exists(ticket_key) ||
            journal_batch_by_ticket[ticket_key] != batch_key)
          return 1'b0;
        journal_batch_by_ticket.delete(ticket_key);
      end
      default: return 1'b0;
    endcase
    return 1'b1;
  endfunction

  // 功能：返回当前 backing mapping 的非拥有测试引用，用于构造 opaque-authority fixture。
  // 输入/输出及副作用：无输入；返回 backing_mapping 原句柄，不修改 mapping。
  // 失败/边界：engine 未 prepare/已 release 时返回 null；生产 API 不暴露此 seam。
  function rdma_dma_mapping journal_mapping_reference();
    return backing_mapping;
  endfunction

  // 功能：播种 submission fence key/reason，供 public query 的 exact-value 测试。
  // 输入/输出及副作用：batch_key/reason 为输入；覆盖两项 engine-owned fence 字段。
  // 失败/边界：允许播种 partial 值以测试 query fail-closed；不安装 journal 行。
  function void seed_submission_fence(string batch_key, string reason);
    fenced_batch_key = batch_key;
    submission_fence_reason = reason;
  endfunction

  // 功能：故意篡改指定 stored batch digest，验证 query 重算而非信任 carried digest。
  // 输入/输出及副作用：batch_key 为输入；命中时翻转 batch_digest 最低位并返回 1。
  // 失败/边界：未知 key 返回 0 且 journal 不变；仅测试 probe 可破坏内部状态。
  function bit tamper_submission_batch_digest(string batch_key);
    if (!submission_journal.exists(batch_key))
      return 1'b0;
    submission_journal[batch_key].batch_digest[0] =
      !submission_journal[batch_key].batch_digest[0];
    return 1'b1;
  endfunction

  // 功能：把 stored item 的 command body 替换为未知 polymorphic 节点，模拟安装后腐化。
  // 输入/输出及副作用：batch_key/request_index/body 为输入；命中时改写 engine-owned row。
  // 失败/边界：record/item/command 缺失、index 越界或 body=null 返回 0 且不修改。
  function bit tamper_submission_command_body(
    string batch_key,
    int unsigned request_index,
    rdma_hw_model body
  );
    if (!submission_journal.exists(batch_key) || body == null ||
        request_index >= submission_journal[batch_key].items.size() ||
        submission_journal[batch_key].items[request_index] == null ||
        submission_journal[batch_key].items[request_index].command == null)
      return 1'b0;
    submission_journal[batch_key].items[request_index].command.body = body;
    return 1'b1;
  endfunction

  // 功能：为 hostile/unknown-body 测试调用 protected command journal snapshot seam。
  // 输入/输出及副作用：source/owner 为输入，snapshot 为输出；创建单一 nonfatal
  //   context 并返回 helper status，不保存 source 引用。
  // 失败/边界：未知 body、bad owner 或 profile 缺失时输出 null 和非空错误。
  function rdma_status snapshot_command_for_journal_probe(
    rdma_cmq_command_desc source,
    rdma_cmq_recovery_owner owner,
    output rdma_cmq_command_desc snapshot
  );
    rdma_cmq_nonfatal_snapshot_context context;

    context = new();
    return snapshot_command_for_journal_locked(
      source, owner, context, snapshot
    );
  endfunction

  // 功能：调用 execution-result 顶层 snapshot seam，覆盖 completion payload alias。
  // 输入/输出及副作用：source 为输入，snapshot 为输出；返回 detached graph status。
  // 失败/边界：未知 payload、null required node 或字段漂移时输出 null、非致命失败。
  function rdma_status snapshot_execution_result_probe(
    rdma_cmq_execution_result source,
    output rdma_cmq_execution_result snapshot
  );
    return snapshot_execution_result_locked(source, snapshot);
  endfunction

  // 功能：调用 recovery-request 顶层 snapshot seam，覆盖 items/proof/owner aliases。
  // 输入/输出及副作用：source 为输入，snapshot 为输出；不安装或修改 journal。
  // 失败/边界：digest、proof 或 nested graph 不完整时输出 null 和非空错误。
  function rdma_status snapshot_recovery_request_probe(
    rdma_cmq_submission_recovery_request source,
    output rdma_cmq_submission_recovery_request snapshot
  );
    return snapshot_recovery_request_locked(source, snapshot);
  endfunction

  // 功能：调用 reset-proof 顶层 snapshot seam，验证 direct-new outer construction。
  // 输入/输出及副作用：source 为输入，snapshot 为输出；不登记 proof authority。
  // 失败/边界：proof digest/tuple/state 非法时输出 null 和非空错误。
  function rdma_status snapshot_reset_proof_probe(
    rdma_cmq_reset_isolation_proof source,
    output rdma_cmq_reset_isolation_proof snapshot
  );
    return snapshot_reset_proof_locked(source, snapshot);
  endfunction

  // 功能：返回 engine 当前安装的 transport 对象 identity，供生命周期测试确认 prepare/reset/reprepare 的替换边界。
  // 输入/输出及副作用：无输入；返回 protected transport 的非拥有测试引用，不修改 engine、facade 或 scheduler 状态。
  // 失败/边界：engine 未成功 prepare 或已 reset/shutdown/clear 时返回 null；调用方不得借此引用改写生产账本。
  function rdma_cmq_transport transport_reference();
    return transport;
  endfunction

  // 功能：执行 restore_mapping 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：source（输入）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：restore_mapping 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function void restore_mapping(rdma_dma_mapping source);
    if (backing_mapping != null && source != null)
      backing_mapping.copy(source);
  endfunction

  // 功能：执行 seed_runtime_counters 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：无显式参数；seed_runtime_counters 读取 对象字段：publish_seq、retire_seq、cq_consume_seq 并使用字段 publish_seq、retire_seq、cq_consume_seq；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：seed_runtime_counters 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function void seed_runtime_counters();
    publish_seq = 11;
    retire_seq = 7;
    cq_consume_seq = 5;
  endfunction

  // 功能：执行 seed_ring_counters 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：seeded_publish_seq（输入）、seeded_retire_seq（输入）；seed_ring_counters 读取 seeded_publish_seq、seeded_retire_seq 并使用字段 publish_seq、retire_seq；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：seed_ring_counters 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function void seed_ring_counters(
    longint unsigned seeded_publish_seq,
    longint unsigned seeded_retire_seq
  );
    publish_seq = seeded_publish_seq;
    retire_seq = seeded_retire_seq;
  endfunction

  // 功能：判断 tokens_in_use_count 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：无显式参数；tokens_in_use_count 读取 对象字段：token_in_use、i 并使用字段 count；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：tokens_in_use_count 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  function int unsigned tokens_in_use_count();
    int unsigned count;

    count = 0;
    foreach (token_in_use[i])
      if (token_in_use[i])
        count++;
    return count;
  endfunction

  // 功能：slot_record_count 只读当前账本/队列状态并计算 int unsigned 计数或可用容量，不推进任何事务游标。
  // 输入/输出及副作用：无显式参数；slot_record_count 读取 对象字段：slots、i 并使用字段 count；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：slot_record_count 先检查 slots[i] != null，再返回 count；拒绝分支不提交部分状态，也不隐式重试。
  function int unsigned slot_record_count();
    int unsigned count;

    count = 0;
    foreach (slots[i])
      if (slots[i] != null)
        count++;
    return count;
  endfunction

  // 功能：command_registry_count 只读当前账本/队列状态并计算 int unsigned 计数或可用容量，不推进任何事务游标。
  // 输入/输出及副作用：无显式参数；command_registry_count 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：command_registry_count 的结果直接由 return command_registry.num() 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function int unsigned command_registry_count();
    return command_registry.num();
  endfunction

  // 功能：entry_registry_count 只读当前账本/队列状态并计算 int unsigned 计数或可用容量，不推进任何事务游标。
  // 输入/输出及副作用：无显式参数；entry_registry_count 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：entry_registry_count 的结果直接由 return entry_registry.num() 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function int unsigned entry_registry_count();
    return entry_registry.num();
  endfunction

  // 功能：terminal_fifo_count 只读当前账本/队列状态并计算 int unsigned 计数或可用容量，不推进任何事务游标。
  // 输入/输出及副作用：无显式参数；terminal_fifo_count 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：terminal_fifo_count 的结果直接由 return terminal_fifo.size() 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function int unsigned terminal_fifo_count();
    return terminal_fifo.size();
  endfunction

  // 功能：diagnostic_fifo_count 只读当前账本/队列状态并计算 int unsigned 计数或可用容量，不推进任何事务游标。
  // 输入/输出及副作用：无显式参数；diagnostic_fifo_count 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：diagnostic_fifo_count 的结果直接由 return diagnostic_fifo.size() 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function int unsigned diagnostic_fifo_count();
    return diagnostic_fifo.size();
  endfunction

  // 功能：在 rdma_cmq_engine_probe 中，slot_state_at 只读查询当前运行时/测试账本，返回槽位、对象或恢复记录的快照而不推进事务。
  // 输入/输出及副作用：sq_index（输入）；slot_state_at 读取 sq_index 并使用字段 slots、state；函数返回 rdma_cmq_slot_state_e，不取得调用方资源所有权。
  // 失败/边界：slot_state_at 先检查 sq_index >= 32 || slots[sq_index] == null，再返回 CMQ_SLOT_FREE；slots[sq_index].state；拒绝分支不提交部分状态，也不隐式重试。
  function rdma_cmq_slot_state_e slot_state_at(int unsigned sq_index);
    if (sq_index >= 32 || slots[sq_index] == null)
      return CMQ_SLOT_FREE;
    return slots[sq_index].state;
  endfunction

  // 功能：在 rdma_cmq_engine_probe 中，install_slot_ticket_function_clone_fault 将输入对象登记或挂接到当前集合/依赖图，并同步维护对应账本和生命周期引用。
  // 输入/输出及副作用：sq_index（输入）、clone_fault（输入）；install_slot_ticket_function_clone_fault 读取 sq_index、clone_fault 并使用字段 source、fault_function、fault_function.kind、fault_function.function_uid、fault_function.object_id、fault_function.generation、fault_function.clone_fault、ticket.function_h；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：install_slot_ticket_function_clone_fault 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  function bit install_slot_ticket_function_clone_fault(
    int unsigned sq_index,
    rdma_cmq_test_clone_fault_e clone_fault
  );
    rdma_function_handle source;
    rdma_cmq_clone_fault_function_handle fault_function;

    if (sq_index >= 32 || slots[sq_index] == null ||
        slots[sq_index].ticket == null ||
        slots[sq_index].ticket.function_h == null)
      return 1'b0;
    source = slots[sq_index].ticket.function_h;
    fault_function = rdma_cmq_clone_fault_function_handle::type_id::create(
      $sformatf("timeout_fault_function_%0d", sq_index)
    );
    if (fault_function == null)
      return 1'b0;
    fault_function.kind = source.kind;
    fault_function.function_uid = source.function_uid;
    fault_function.object_id = source.object_id;
    fault_function.generation = source.generation;
    fault_function.clone_fault = clone_fault;
    slots[sq_index].ticket.function_h = fault_function;
    return 1'b1;
  endfunction

  // 功能：执行 set_slot_ticket_function_clone_fault 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：sq_index（输入）、clone_fault（输入）；调用方必须先完成输入对象的空值、authority 和 generation 校验；成功时更新本对象配置/状态并保存非拥有引用，返回 bit。
  // 失败/边界：set_slot_ticket_function_clone_fault 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function bit set_slot_ticket_function_clone_fault(
    int unsigned sq_index,
    rdma_cmq_test_clone_fault_e clone_fault
  );
    rdma_cmq_clone_fault_function_handle fault_function;

    if (sq_index >= 32 || slots[sq_index] == null ||
        slots[sq_index].ticket == null ||
        !$cast(fault_function, slots[sq_index].ticket.function_h))
      return 1'b0;
    fault_function.clone_fault = clone_fault;
    return 1'b1;
  endfunction

  // 功能：在 rdma_cmq_engine_probe 中，token_in_use_at 只读查询当前运行时/测试账本，返回槽位、对象或恢复记录的快照而不推进事务。
  // 输入/输出及副作用：token_index（输入）；token_in_use_at 读取 token_index 并使用字段 token_in_use；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：token_in_use_at 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  function bit token_in_use_at(int unsigned token_index);
    if (token_index >= 32)
      return 1'b0;
    return token_in_use[token_index];
  endfunction

  // 功能：在 rdma_cmq_engine_probe 中，token_incarnation_at 只读查询当前运行时/测试账本，返回槽位、对象或恢复记录的快照而不推进事务。
  // 输入/输出及副作用：token_index（输入）；token_incarnation_at 读取 token_index 并使用字段 token_incarnation；函数返回 bit [58:0]，不取得调用方资源所有权。
  // 失败/边界：token_incarnation_at 先检查 token_index >= 32，再返回 '0；token_incarnation[token_index]；拒绝分支不提交部分状态，也不隐式重试。
  function bit [58:0] token_incarnation_at(int unsigned token_index);
    if (token_index >= 32)
      return '0;
    return token_incarnation[token_index];
  endfunction

  // 功能：执行 seed_token_incarnation 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：token_index（输入）、incarnation（输入）；seed_token_incarnation 读取 token_index、incarnation 并使用输入参数和固定枚举/常量；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：seed_token_incarnation 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function void seed_token_incarnation(
    int unsigned token_index,
    bit [58:0] incarnation
  );
    if (token_index < 32)
      token_incarnation[token_index] = incarnation;
  endfunction

  // 功能：执行 seed_all_token_incarnations 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：incarnation（输入）；seed_all_token_incarnations 读取 incarnation 并使用输入参数和固定枚举/常量；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：seed_all_token_incarnations 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function void seed_all_token_incarnations(bit [58:0] incarnation);
    foreach (token_incarnation[i])
      token_incarnation[i] = incarnation;
  endfunction

  // 功能：执行 seed_terminal_completion 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：completion（输入）；seed_terminal_completion 读取 completion 并使用输入参数和固定枚举/常量；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：seed_terminal_completion 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function void seed_terminal_completion(rdma_cmq_completion completion);
    terminal_fifo.push_back(completion);
  endfunction

  // 功能：执行 tamper_empty_ledger 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：fault（输入）；tamper_empty_ledger 读取 fault 并使用字段 stray_record；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：tamper_empty_ledger 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function void tamper_empty_ledger(
    rdma_cmq_test_empty_ledger_fault_e fault
  );
    rdma_cmq_slot_record stray_record;

    case (fault)
      RDMA_CMQ_TEST_EMPTY_LEDGER_COUNTER: cq_consume_seq++;
      RDMA_CMQ_TEST_EMPTY_LEDGER_SLOT: begin
        stray_record = rdma_cmq_slot_record::type_id::create(
          "empty_ledger_stray_slot"
        );
        slots[0] = stray_record;
      end
      RDMA_CMQ_TEST_EMPTY_LEDGER_TOKEN: token_in_use[0] = 1'b1;
      RDMA_CMQ_TEST_EMPTY_LEDGER_REGISTRY: begin
        stray_record = rdma_cmq_slot_record::type_id::create(
          "empty_ledger_stray_registry"
        );
        command_registry["empty_ledger_stray"] = stray_record;
        entry_registry["empty_ledger_stray"] = stray_record;
      end
      default: begin
      end
    endcase
  endfunction

  // 功能：执行 tamper_published_ledger 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：ticket（输入）、fault（输入）；tamper_published_ledger 读取 ticket、fault 并使用字段 slots；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：tamper_published_ledger 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function bit tamper_published_ledger(
    rdma_cmq_ticket ticket,
    rdma_cmq_test_published_ledger_fault_e fault
  );
    if (ticket == null || ticket.sq_index >= 32 ||
        slots[ticket.sq_index] == null)
      return 1'b0;
    case (fault)
      RDMA_CMQ_TEST_PUBLISHED_LEDGER_TOKEN_MISSING:
        token_in_use[ticket.command_id[4:0]] = 1'b0;
      RDMA_CMQ_TEST_PUBLISHED_LEDGER_SLOT_MISSING:
        slots[ticket.sq_index] = null;
      RDMA_CMQ_TEST_PUBLISHED_LEDGER_REGISTRY_MISSING:
        command_registry.delete(command_key(ticket));
      default: return 1'b0;
    endcase
    return 1'b1;
  endfunction

  // 功能：执行 tamper_cancel_ledger 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：tickets（输入）、fault（输入）；tamper_cancel_ledger 读取 tickets、fault 并使用字段 record、target_index、software_key；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：tamper_cancel_ledger 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function bit tamper_cancel_ledger(
    rdma_cmq_ticket tickets[],
    rdma_cmq_test_cancel_ledger_fault_e fault
  );
    rdma_cmq_slot_record record;
    int target_index;
    string software_key;

    if (tickets.size() == 0 || tickets[0] == null ||
        tickets[0].sq_index >= 32 || slots[tickets[0].sq_index] == null)
      return 1'b0;
    record = slots[tickets[0].sq_index];
    case (fault)
      RDMA_CMQ_TEST_CANCEL_LEDGER_STRAY_TOKEN: begin
        target_index = -1;
        foreach (token_in_use[i]) begin
          if (target_index < 0 && !token_in_use[i])
            target_index = i;
        end
        if (target_index < 0)
          return 1'b0;
        token_in_use[target_index] = 1'b1;
      end
      RDMA_CMQ_TEST_CANCEL_LEDGER_MOVED_SLOT: begin
        target_index = -1;
        foreach (slots[i]) begin
          if (target_index < 0 && slots[i] == null)
            target_index = i;
        end
        if (target_index < 0)
          return 1'b0;
        slots[target_index] = record;
        slots[tickets[0].sq_index] = null;
      end
      RDMA_CMQ_TEST_CANCEL_LEDGER_DUPLICATE_SLOT: begin
        if (tickets.size() < 2 || tickets[1] == null ||
            tickets[1].sq_index >= 32 ||
            slots[tickets[1].sq_index] == null)
          return 1'b0;
        slots[tickets[1].sq_index] = record;
      end
      RDMA_CMQ_TEST_CANCEL_LEDGER_WRONG_COMMAND_KEY: begin
        software_key = command_key(record.ticket);
        if (!command_registry.exists(software_key) ||
            command_registry[software_key] != record)
          return 1'b0;
        command_registry.delete(software_key);
        command_registry["cancel-ledger-wrong-key"] = record;
      end
      default: return 1'b0;
    endcase
    return 1'b1;
  endfunction

  // 功能：执行 tamper_balanced_cancel_membership 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：quarantined_ticket（输入）、published_ticket（输入）；tamper_balanced_cancel_membership 读取 quarantined_ticket、published_ticket 并使用字段 stray_token、quarantined_record；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：tamper_balanced_cancel_membership 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function bit tamper_balanced_cancel_membership(
    rdma_cmq_ticket quarantined_ticket,
    rdma_cmq_ticket published_ticket
  );
    rdma_cmq_slot_record quarantined_record;
    int stray_token;

    if (quarantined_ticket == null || published_ticket == null ||
        quarantined_ticket.sq_index >= 32 ||
        published_ticket.sq_index >= 32 ||
        slots[quarantined_ticket.sq_index] == null ||
        slots[published_ticket.sq_index] == null ||
        slots[quarantined_ticket.sq_index].state !=
          CMQ_SLOT_TIMED_OUT_QUARANTINED ||
        slots[published_ticket.sq_index].state != CMQ_SLOT_PUBLISHED)
      return 1'b0;
    stray_token = -1;
    foreach (token_in_use[i]) begin
      if (stray_token < 0 && !token_in_use[i])
        stray_token = i;
    end
    if (stray_token < 0)
      return 1'b0;
    quarantined_record = slots[quarantined_ticket.sq_index];
    token_in_use[stray_token] = 1'b1;
    command_registry["cancel-ledger-stray-member"] = quarantined_record;
    return 1'b1;
  endfunction

  // 功能：执行 tamper_recovery_ticket_x 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：ticket（输入）、fault（输入）；tamper_recovery_ticket_x 读取 ticket、fault 并使用字段 stray_token、record、ticket.command_id、ticket.absolute_deadline；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：tamper_recovery_ticket_x 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function bit tamper_recovery_ticket_x(
    rdma_cmq_ticket ticket,
    rdma_cmq_test_recovery_x_fault_e fault
  );
    rdma_cmq_slot_record record;
    int stray_token;

    if (ticket == null || ticket.sq_index >= 32 ||
        slots[ticket.sq_index] == null ||
        slots[ticket.sq_index].ticket == null)
      return 1'b0;
    stray_token = -1;
    foreach (token_in_use[i]) begin
      if (stray_token < 0 && !token_in_use[i])
        stray_token = i;
    end
    if (stray_token < 0)
      return 1'b0;
    record = slots[ticket.sq_index];
    case (fault)
      RDMA_CMQ_TEST_RECOVERY_X_COMMAND_ID:
        record.ticket.command_id = 'x;
      RDMA_CMQ_TEST_RECOVERY_X_ABSOLUTE_DEADLINE:
        record.ticket.absolute_deadline = 'x;
      default: return 1'b0;
    endcase
    token_in_use[stray_token] = 1'b1;
    return 1'b1;
  endfunction

  // 功能：执行 tamper_slot_incarnation 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：sq_index（输入）；tamper_slot_incarnation 读取 sq_index 并使用字段 slots；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：tamper_slot_incarnation 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function bit tamper_slot_incarnation(int unsigned sq_index);
    if (sq_index >= 32 || slots[sq_index] == null)
      return 1'b0;
    slots[sq_index].slot_sequence++;
    return 1'b1;
  endfunction

  // 功能：执行 tamper_slot_retirement_incarnation 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：sq_index（输入）；tamper_slot_retirement_incarnation 读取 sq_index 并使用字段 record、old_entry_key、record.sq_wrap、ticket.sq_wrap；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：tamper_slot_retirement_incarnation 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function bit tamper_slot_retirement_incarnation(int unsigned sq_index);
    rdma_cmq_slot_record record;
    string old_entry_key;

    if (sq_index >= 32 || slots[sq_index] == null ||
        slots[sq_index].ticket == null)
      return 1'b0;
    record = slots[sq_index];
    old_entry_key = entry_key(record.sq_index, record.sq_wrap);
    if (!entry_registry.exists(old_entry_key) ||
        entry_registry[old_entry_key] != record)
      return 1'b0;
    entry_registry.delete(old_entry_key);
    record.slot_sequence += 32;
    record.sq_wrap = !record.sq_wrap;
    record.ticket.slot_sequence += 32;
    record.ticket.sq_wrap = record.sq_wrap;
    entry_registry[entry_key(record.sq_index, record.sq_wrap)] = record;
    return 1'b1;
  endfunction

  // 功能：在 rdma_cmq_engine_probe 中，slot_expected_variant 读取指定 SQ slot 的 expected-response variant，供测试核对 ticket 与解码 profile 的绑定。
  // 输入/输出及副作用：sq_index（输入）；slot_expected_variant 读取 sq_index 并使用字段 slots；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：slot_expected_variant 的结果直接由 return "" 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function string slot_expected_variant(int unsigned sq_index);
    if (sq_index >= 32 || slots[sq_index] == null ||
        slots[sq_index].expected == null)
      return "";
    return slots[sq_index].expected.variant;
  endfunction

  // 功能：probe_same_handle 比较 lhs、rhs 与当前 authority/状态字段，返回布尔结果供上层执行精确分支。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；probe_same_handle 读取 lhs、rhs 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：probe_same_handle 的结果直接由 return same_handle(lhs, rhs) 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function bit probe_same_handle(rdma_handle lhs, rdma_handle rhs);
    return same_handle(lhs, rhs);
  endfunction

  // 功能：probe_same_opcode 比较 lhs、rhs 与当前 authority/状态字段，返回布尔结果供上层执行精确分支。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；probe_same_opcode 读取 lhs、rhs 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：probe_same_opcode 的结果直接由 return same_opcode_value(lhs, rhs) 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function bit probe_same_opcode(
    rdma_cmq_opcode_key lhs,
    rdma_cmq_opcode_key rhs
  );
    return same_opcode_value(lhs, rhs);
  endfunction

  // 功能：probe_same_image 比较 lhs、rhs 与当前 authority/状态字段，返回布尔结果供上层执行精确分支。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；probe_same_image 读取 lhs、rhs 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：probe_same_image 的结果直接由 return same_image_value(lhs, rhs) 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function bit probe_same_image(rdma_hw_image lhs, rdma_hw_image rhs);
    return same_image_value(lhs, rhs);
  endfunction

  // 功能：在 rdma_cmq_engine_probe 中，probe_body_value_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：body（输入）；probe_body_value_key 读取 body 并使用输入参数和固定枚举/常量；函数返回 string，不取得调用方资源所有权。
// 失败/边界：probe_body_value_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  function string probe_body_value_key(rdma_hw_model body);
    return body_value_key(body);
  endfunction

  // 功能：在 rdma_cmq_engine_probe 中，probe_authority_handle_matches 逐字段比较输入快照或镜像，确认其身份、布局和 payload 完全一致后返回布尔结果。
  // 输入/输出及副作用：expected（输入）；probe_authority_handle_matches 读取 expected 并使用字段 cmq_snapshot、cmq_snapshot.handle；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：probe_authority_handle_matches 只读输入并返回 bit；边界由函数体现有分支决定，不修改状态或转移资源。
  function bit probe_authority_handle_matches(rdma_handle expected);
    return cmq_snapshot != null && cmq_snapshot.handle != null &&
           same_handle(cmq_snapshot.handle, expected);
  endfunction

  // 功能：probe_is_authority_handle 比较 candidate 与当前 authority/状态字段，返回布尔结果供上层执行精确分支。
  // 输入/输出及副作用：candidate（输入）；probe_is_authority_handle 读取 candidate 并使用字段 cmq_snapshot、cmq_snapshot.handle；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：probe_is_authority_handle 只读输入并返回 bit；边界由函数体现有分支决定，不修改状态或转移资源。
  function bit probe_is_authority_handle(rdma_handle candidate);
    return candidate != null && cmq_snapshot != null &&
           candidate == cmq_snapshot.handle;
  endfunction

  // 功能：slot_ticket_command_id 按 SQ 索引读取 slots[sq_index] 的 ticket.command_id，供测试定位对应 CMQ 命令。
  // 输入/输出及副作用：sq_index（输入）；slot_ticket_command_id 读取 sq_index 并使用字段 slots、ticket.command_id、ticket；函数返回 longint unsigned，不取得调用方资源所有权。
  // 失败/边界：slot_ticket_command_id 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  function longint unsigned slot_ticket_command_id(int unsigned sq_index);
    if (sq_index >= 32 || slots[sq_index] == null ||
        slots[sq_index].ticket == null)
      return 0;
    return slots[sq_index].ticket.command_id;
  endfunction

  // 功能：确认 release 失败后的 POISONED engine 只保留 Host-memory/backing
  //   重试 authority，所有 runtime 协作者、transport 和游标均已清空。
  // 输入/输出及副作用：无输入；只读 engine_state、backing/host_mem、协作者和
  //   计数器并返回 bit，不修改测试或 DUT 状态。
  // 失败/边界：任一运行引用残留、transport 非空、backing 缺失或计数器非零时
  //   返回 0；不尝试 release 或修复账本。
  function bit retry_only_poisoned();
    return engine_state == RDMA_CMQ_ENGINE_POISONED &&
           host_mem != null && backing_mapping != null &&
           prepared_binding == null && dma_context == null &&
           cmq_snapshot == null && scheduler == null &&
           transport == null && profile == null &&
           publish_seq == 0 && retire_seq == 0 && cq_consume_seq == 0;
  endfunction

  // 功能：drop_host_mem_authority 使用 当前对象字段 执行函数体规定的状态更新；不修改未列出的对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；drop_host_mem_authority 读取 对象字段：host_mem 并使用字段 host_mem；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：drop_host_mem_authority 无返回值，仅执行 host_mem=null；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  function void drop_host_mem_authority();
    host_mem = null;
  endfunction

  // 功能：执行 restore_host_mem_authority 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：source（输入）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：restore_host_mem_authority 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function void restore_host_mem_authority(rdma_host_mem_api source);
    host_mem = source;
  endfunction

  // 功能：确认缺少 Host-memory release authority 的 POISONED engine 仅保留
  //   backing identity，runtime 协作者、transport 和游标均已清空。
  // 输入/输出及副作用：无输入；只读 engine_state、backing/host_mem、协作者和
  //   计数器并返回 bit，不修改测试或 DUT 状态。
  // 失败/边界：host_mem 仍存在、任一运行引用残留、transport 非空、backing
  //   缺失或计数器非零时返回 0；不伪造可重试 adapter。
  function bit missing_host_mem_poisoned();
    return engine_state == RDMA_CMQ_ENGINE_POISONED &&
           host_mem == null && backing_mapping != null &&
           prepared_binding == null && dma_context == null &&
           cmq_snapshot == null && scheduler == null &&
           transport == null && profile == null &&
           publish_seq == 0 && retire_seq == 0 && cq_consume_seq == 0;
  endfunction

  // 功能：执行 tamper_mapping 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：kind（输入）；tamper_mapping 读取 kind 并使用字段 function_h.kind、backing_mapping.pasid_valid、backing_mapping.dma_domain_valid、backing_mapping.owner_h、owner_h.kind、backing_mapping.direction、backing_mapping.state、permissions.device_read；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：tamper_mapping 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  function void tamper_mapping(rdma_cmq_mapping_tamper_e kind);
    if (backing_mapping == null)
      return;
    case (kind)
      RDMA_CMQ_TAMPER_FUNCTION_KIND:
        backing_mapping.function_h.kind = RDMA_RESOURCE_QP;
      RDMA_CMQ_TAMPER_FUNCTION_UID:
        backing_mapping.function_h.function_uid++;
      RDMA_CMQ_TAMPER_FUNCTION_OBJECT:
        backing_mapping.function_h.object_id++;
      RDMA_CMQ_TAMPER_FUNCTION_GENERATION:
        backing_mapping.function_h.generation++;
      RDMA_CMQ_TAMPER_BDF:
        backing_mapping.requester_bdf.bus++;
      RDMA_CMQ_TAMPER_PASID_VALID:
        backing_mapping.pasid_valid = !backing_mapping.pasid_valid;
      RDMA_CMQ_TAMPER_PASID:
        backing_mapping.pasid++;
      RDMA_CMQ_TAMPER_DMA_DOMAIN_VALID:
        backing_mapping.dma_domain_valid =
          !backing_mapping.dma_domain_valid;
      RDMA_CMQ_TAMPER_DMA_DOMAIN:
        backing_mapping.dma_domain_id++;
      RDMA_CMQ_TAMPER_OWNER_NULL:
        backing_mapping.owner_h = null;
      RDMA_CMQ_TAMPER_OWNER_KIND:
        backing_mapping.owner_h.kind = RDMA_RESOURCE_CQ;
      RDMA_CMQ_TAMPER_OWNER_UID:
        backing_mapping.owner_h.function_uid++;
      RDMA_CMQ_TAMPER_OWNER_OBJECT:
        backing_mapping.owner_h.object_id++;
      RDMA_CMQ_TAMPER_OWNER_GENERATION:
        backing_mapping.owner_h.generation++;
      RDMA_CMQ_TAMPER_DIRECTION:
        backing_mapping.direction = RDMA_DMA_DEVICE_READ;
      RDMA_CMQ_TAMPER_STATE:
        backing_mapping.state = RDMA_MAPPING_FROZEN;
      RDMA_CMQ_TAMPER_SIZE:
        backing_mapping.size--;
      RDMA_CMQ_TAMPER_PERMISSION_READ:
        backing_mapping.permissions.device_read = 1'b0;
      RDMA_CMQ_TAMPER_PERMISSION_WRITE:
        backing_mapping.permissions.device_write = 1'b0;
      RDMA_CMQ_TAMPER_IOVA_ALIGNMENT:
        backing_mapping.iova.value++;
      RDMA_CMQ_TAMPER_BACKING_ALIGNMENT:
        backing_mapping.backing_addr.value++;
      RDMA_CMQ_TAMPER_IOVA_RANGE:
        backing_mapping.iova.value = 64'hffff_ffff_ffff_f800;
      RDMA_CMQ_TAMPER_BACKING_RANGE:
        backing_mapping.backing_addr.value = 64'hffff_ffff_ffff_f800;
      RDMA_CMQ_TAMPER_PERMISSION_ATOMIC:
        backing_mapping.permissions.atomic = 1'b1;
      default: return;
    endcase
  endfunction
endclass

typedef enum int unsigned {
  RDMA_CMQ_BAD_MAPPING_ATOMIC,
  RDMA_CMQ_BAD_MAPPING_IOVA_ALIGNMENT,
  RDMA_CMQ_BAD_MAPPING_BACKING_ALIGNMENT,
  RDMA_CMQ_BAD_MAPPING_IOVA_RANGE,
  RDMA_CMQ_BAD_MAPPING_BACKING_RANGE
} rdma_cmq_bad_mapping_kind_e;

class rdma_cmq_bad_mapping_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_bad_mapping_mem)

  rdma_cmq_bad_mapping_kind_e bad_kind;

  // 功能：构造 rdma_cmq_bad_mapping_mem，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：bad_kind=RDMA_CMQ_BAD_MAPPING_ATOMIC。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_bad_mapping_mem 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_bad_mapping_mem");
    super.new(name);
    bad_kind = RDMA_CMQ_BAD_MAPPING_ATOMIC;
  endfunction

  // 功能：在 rdma_cmq_bad_mapping_mem 中，allocate 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：request_context（输入）、size（输入）、alignment（输入）、direction（输入）、mapping（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或
  //   output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;
    int region_index;

    status = super.allocate(request_context, size, alignment, direction,
                            mapping);
    if (!status.ok() || mapping == null)
      return status;
    region_index = regions.size() - 1;
    case (bad_kind)
      RDMA_CMQ_BAD_MAPPING_ATOMIC: begin
        mapping.permissions.atomic = 1'b1;
        regions[region_index].mapping.permissions.atomic = 1'b1;
      end
      RDMA_CMQ_BAD_MAPPING_IOVA_ALIGNMENT: begin
        mapping.iova.value++;
        regions[region_index].mapping.iova.value++;
      end
      RDMA_CMQ_BAD_MAPPING_BACKING_ALIGNMENT: begin
        mapping.backing_addr.value++;
        regions[region_index].mapping.backing_addr.value++;
      end
      RDMA_CMQ_BAD_MAPPING_IOVA_RANGE: begin
        mapping.iova.value = 64'hffff_ffff_ffff_f800;
        regions[region_index].mapping.iova.value = mapping.iova.value;
      end
      RDMA_CMQ_BAD_MAPPING_BACKING_RANGE: begin
        mapping.backing_addr.value = 64'hffff_ffff_ffff_f800;
        regions[region_index].mapping.backing_addr.value =
          mapping.backing_addr.value;
      end
    endcase
    return status;
  endfunction
endclass

class rdma_cmq_upper_boundary_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_upper_boundary_mem)

  // 功能：构造 rdma_cmq_upper_boundary_mem，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_upper_boundary_mem 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_upper_boundary_mem");
    super.new(name);
  endfunction

  // 功能：在 rdma_cmq_upper_boundary_mem 中，allocate 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：request_context（输入）、size（输入）、alignment（输入）、direction（输入）、mapping（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或
  //   output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;
    int region_index;

    status = super.allocate(request_context, size, alignment, direction,
                            mapping);
    if (!status.ok() || mapping == null)
      return status;
    region_index = regions.size() - 1;
    mapping.iova.value = 64'hffff_ffff_ffff_f000;
    mapping.backing_addr.value = 64'hffff_ffff_ffff_f000;
    regions[region_index].mapping.iova = mapping.iova;
    regions[region_index].mapping.backing_addr = mapping.backing_addr;
    return status;
  endfunction
endclass

typedef enum int unsigned {
  RDMA_CMQ_ALLOCATE_NULL_NO_CANDIDATE,
  RDMA_CMQ_ALLOCATE_NULL_WITH_CANDIDATE,
  RDMA_CMQ_ALLOCATE_FAILURE_WITH_CANDIDATE
} rdma_cmq_allocate_result_e;

class rdma_cmq_allocate_result_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_allocate_result_mem)

  rdma_cmq_allocate_result_e result_kind;

  // 功能：构造 rdma_cmq_allocate_result_mem，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：result_kind=RDMA_CMQ_ALLOCATE_NULL_NO_CANDIDATE。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_allocate_result_mem 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_allocate_result_mem");
    super.new(name);
    result_kind = RDMA_CMQ_ALLOCATE_NULL_NO_CANDIDATE;
  endfunction

  // 功能：在 rdma_cmq_allocate_result_mem 中，allocate 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：request_context（输入）、size（输入）、alignment（输入）、direction（输入）、mapping（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或
  //   output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;

    if (result_kind == RDMA_CMQ_ALLOCATE_NULL_NO_CANDIDATE) begin
      mapping = null;
      record_call("allocate", request_context, null, size, alignment,
                  direction);
      return null;
    end
    status = super.allocate(request_context, size, alignment, direction,
                            mapping);
    if (!status.ok() || mapping == null)
      return status;
    if (result_kind == RDMA_CMQ_ALLOCATE_NULL_WITH_CANDIDATE)
      return null;
    return rdma_status::make(
      RDMA_SC_RESOURCE_EXHAUSTED,
      "injected allocation failure with candidate"
    );
  endfunction
endclass

class rdma_cmq_null_write_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_null_write_mem)

  // 功能：构造 rdma_cmq_null_write_mem，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_null_write_mem 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_null_write_mem");
    super.new(name);
  endfunction

  // 功能：在 rdma_cmq_null_write_mem 中，write 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：mapping（输入）、offset（输入）、data（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending
  //   journal，并通过 output 返回结果。
  // 失败/边界：write 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    rdma_status status;

    status = super.write(mapping, offset, data);
    if (!status.ok())
      return status;
    return null;
  endfunction
endclass

class rdma_cmq_null_release_once_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_null_release_once_mem)

  bit return_null_once;

  // 功能：构造 rdma_cmq_null_release_once_mem，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：return_null_once=1'b1。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_null_release_once_mem 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_null_release_once_mem");
    super.new(name);
    return_null_once = 1'b1;
  endfunction

  // 功能：在 rdma_cmq_null_release_once_mem 中，release 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：mapping（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  virtual function rdma_status \release (rdma_dma_mapping mapping);
    if (return_null_once) begin
      return_null_once = 1'b0;
      record_call("release", null, mapping);
      return null;
    end
    return super.\release (mapping);
  endfunction
endclass

class rdma_cmq_short_mapping_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_cmq_short_mapping_mem)

  // 功能：构造 rdma_cmq_short_mapping_mem，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_short_mapping_mem 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_short_mapping_mem");
    super.new(name);
  endfunction

  // 功能：在 rdma_cmq_short_mapping_mem 中，allocate 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：request_context（输入）、size（输入）、alignment（输入）、direction（输入）、mapping（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或
  //   output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;

    status = super.allocate(request_context, size, alignment, direction,
                            mapping);
    if (status.ok() && mapping != null) begin
      mapping.size = size - 1'b1;
      regions[regions.size() - 1].mapping.size = size - 1'b1;
    end
    return status;
  endfunction
endclass

class rdma_cmq_engine_test extends uvm_test;
  `uvm_component_utils(rdma_cmq_engine_test)

  localparam longint unsigned TEST_FUNCTION_UID =
    64'h1234_5678_90ab_cdef;
  localparam int unsigned TEST_FUNCTION_ID = 32'h1020_3040;
  localparam int unsigned TEST_GENERATION = 32'd9;
  localparam int unsigned TEST_CMQ_ID = 32'h5566_7788;
  localparam longint unsigned TEST_CQ_OFFSET = 64'd2048;

  // 功能：构造 rdma_cmq_engine_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_engine_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_engine_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 rdma_cmq_engine_test 中，configure_submission_factory_faults 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：无显式参数；configure_submission_factory_faults 先依据 依赖存在性、authority 和 generation 条件 校验 函数体读取的依赖；成功时更新本对象配置/状态并保存非拥有引用，返回 void。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  function automatic void configure_submission_factory_faults();
    uvm_factory factory;

    factory = uvm_factory::get();
    factory.set_type_override_by_type(
      rdma_cmq_slot_context::get_type(),
      rdma_cmq_failing_slot_context::get_type()
    );
    factory.set_type_override_by_type(
      rdma_cmq_ticket::get_type(), rdma_cmq_failing_ticket::get_type()
    );
    factory.set_type_override_by_type(
      rdma_cmq_slot_record::get_type(),
      rdma_cmq_failing_slot_record::get_type()
    );
    factory.set_type_override_by_type(
      rdma_doorbell_dependency::get_type(),
      rdma_cmq_failing_dependency::get_type()
    );
    factory.set_type_override_by_type(
      rdma_doorbell_desc::get_type(),
      rdma_cmq_failing_doorbell_desc::get_type()
    );
  endfunction

  // 功能：在 rdma_cmq_engine_test 中，disarm_submission_factory_faults 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；disarm_submission_factory_faults 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：disarm_submission_factory_faults 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  function automatic void disarm_submission_factory_faults();
    rdma_cmq_failing_slot_context::disarm();
    rdma_cmq_failing_ticket::disarm();
    rdma_cmq_failing_slot_record::disarm();
    rdma_cmq_failing_dependency::disarm();
    rdma_cmq_failing_dependency::disarm_capture();
    rdma_cmq_failing_doorbell_desc::disarm();
  endfunction

  // 功能：在 rdma_cmq_engine_test 中，submission_factory_fault_armed 检查当前事务或测试证据是否满足指定布尔条件，供恢复分类和断言选择后续路径。
  // 输入/输出及副作用：无显式参数；submission_factory_fault_armed 读取 对象字段：rdma_cmq_failing_slot_context、rdma_cmq_failing_ticket、rdma_cmq_failing_slot_record、rdma_cmq_failing_dependency、rdma_cmq_failing_doorbell_desc 并使用字段 rdma_cmq_failing_slot_context、rdma_cmq_failing_ticket、rdma_cmq_failing_slot_record、rdma_cmq_failing_dependency、rdma_cmq_failing_doorbell_desc；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：submission_factory_fault_armed 只读输入并返回 bit；边界由函数体现有分支决定，不修改状态或转移资源。
  function automatic bit submission_factory_fault_armed();
    return rdma_cmq_failing_slot_context::armed() ||
           rdma_cmq_failing_ticket::armed() ||
           rdma_cmq_failing_slot_record::armed() ||
           rdma_cmq_failing_dependency::armed() ||
           rdma_cmq_failing_doorbell_desc::armed();
  endfunction

  // 功能：在 rdma_cmq_engine_test 中，expect_status 在测试中执行 expect_status 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、status（输入）、expected（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_status 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null) begin
      `uvm_error(label, "engine returned a null status")
      return;
    end
    if (status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)", expected.name(),
                           status.code.name(), status.convert2string()))
  endfunction

  // 功能：make_binding 创建独立的 rdma_function_binding；根据 name、binding_state 设置字段 binding、binding.function_uid、binding.global_function_id、binding.generation、pcie.bdf、base.value、size、enabled、binding.notify_bar_id、notify_base.value，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、binding_state（输入）；make_binding 读取 name、binding_state 并使用字段 binding、binding.function_uid、binding.global_function_id、binding.generation、pcie.bdf、base.value、size、enabled；函数返回 rdma_function_binding，不取得调用方资源所有权。
  // 失败/边界：make_binding 的结果直接由 return binding 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_function_binding make_binding(
    string name,
    rdma_binding_state_e binding_state
  );
    rdma_function_binding binding;
    rdma_interrupt_vector_binding vector;

    binding = rdma_function_binding::type_id::create(name);
    binding.function_uid = TEST_FUNCTION_UID;
    binding.global_function_id = TEST_FUNCTION_ID;
    binding.generation = TEST_GENERATION;
    binding.pcie.bdf = '{segment:16'h0001, bus:8'h42,
                         device:5'h03, function_num:3'h1};
    if (!binding.configure_identity_from_legacy_mirrors(
          16'h0, 32'h1, RDMA_FUNCTION_PF).ok())
      `uvm_error("BINDING", "legacy binding identity configuration failed")
    binding.pcie.bar[0].base.value = 64'h0000_0000_8000_0000;
    binding.pcie.bar[0].size = 64'h0001_0000;
    binding.pcie.bar[0].enabled = 1'b1;
    binding.notify_bar_id = 0;
    binding.notify_base.value = 64'h0000_0000_8000_2000;
    binding.notify_size = 64'h2000;
    binding.state = binding_state;
    binding.owner_h = binding.make_handle();
    binding.queue_dma.requester_bdf = binding.pcie.bdf;
    binding.queue_dma.pasid_valid = 1'b1;
    binding.queue_dma.pasid = 20'h34567;
    binding.queue_dma.dma_domain_valid = 1'b1;
    binding.queue_dma.dma_domain_id = 32'h1122_3344;
    binding.queue_caps.min_cq_depth = 16;
    binding.queue_caps.max_cq_depth = 32768;
    binding.queue_caps.min_srq_depth = 16;
    binding.queue_caps.max_srq_depth = 32768;
    binding.queue_caps.max_ceq_depth = 4096;
    binding.queue_caps.max_aeq_depth = 4096;
    binding.queue_caps.max_wq_sge = 8;
    binding.queue_caps.max_queue_ring_bytes = 32'h0020_0000;
    binding.queue_caps.max_sgb_bytes = 32'h0040_0000;
    vector = '{default:'0};
    vector.function_local_vector = 3;
    vector.hardware_eq_vector = 17;
    vector.msix_table_index = 5;
    vector.enabled = 1'b1;
    binding.interrupt_vectors.push_back(vector);
    binding.pcie.mse = 1'b1;
    binding.pcie.bme = 1'b1;
    binding.notify_valid = 1'b1;
    binding.notify_ready = 1'b1;
    binding.dmi_valid = 1'b1;
    binding.dmi_ready = 1'b1;
    binding.vft_valid = 1'b1;
    binding.vft_ready = 1'b1;
    return binding;
  endfunction

  // 功能：make_cmq 创建独立的 rdma_cmq；根据 name、binding、depth 设置字段 cmq、cmq.handle、handle.kind、handle.function_uid、handle.object_id、handle.generation、cmq.owner、cmq.state、cmq.depth，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、binding（输入）、depth（输入）；make_cmq 读取 name、binding、depth 并使用字段 cmq、cmq.handle、handle.kind、handle.function_uid、handle.object_id、handle.generation、cmq.owner、cmq.state；函数返回 rdma_cmq，不取得调用方资源所有权。
  // 失败/边界：make_cmq 的结果直接由 return cmq 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_cmq make_cmq(
    string name,
    rdma_function_binding binding,
    int unsigned depth = 32
  );
    rdma_cmq cmq;

    cmq = rdma_cmq::type_id::create(name);
    cmq.handle = rdma_handle::type_id::create({name, "_handle"});
    cmq.handle.kind = RDMA_RESOURCE_CMQ;
    cmq.handle.function_uid = binding.function_uid;
    cmq.handle.object_id = TEST_CMQ_ID;
    cmq.handle.generation = binding.generation;
    cmq.owner = binding.make_handle();
    cmq.state = RDMA_RESOURCE_ALLOCATED;
    cmq.depth = depth;
    return cmq;
  endfunction

  // 功能：make_command 创建独立的 rdma_cmq_command_desc；根据 name、binding、opcode、marker、timeout_value 设置字段 command、command.function_h、command.opcode_key、opcode_key.profile_name、opcode_key.opcode、opcode_key.variant、target_h、target_h.kind、target_h.function_uid、target_h.object_id，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、binding（输入）、opcode（输入）、marker（输入）、us（输入）；make_command 读取 name、binding、opcode、marker、timeout_value 并使用字段 command、command.function_h、command.opcode_key、opcode_key.profile_name、opcode_key.opcode、opcode_key.variant、target_h、target_h.kind；函数返回 rdma_cmq_command_desc，不取得调用方资源所有权。
  // 失败/边界：make_command 的结果直接由 return command 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_cmq_command_desc make_command(
    string name,
    rdma_function_binding binding,
    bit [31:0] opcode,
    byte unsigned marker,
    time timeout_value = 1us
  );
    rdma_cmq_command_desc command;
    rdma_cmq_sqe_model body;
    rdma_handle target_h;

    command = rdma_cmq_command_desc::type_id::create(name);
    command.function_h = binding.make_handle();
    command.opcode_key = rdma_cmq_opcode_key::type_id::create(
      {name, "_key"}
    );
    command.opcode_key.profile_name = "cmq_engine_test";
    command.opcode_key.opcode = opcode;
    command.opcode_key.variant = $sformatf("variant_%02h", opcode[7:0]);
    target_h = rdma_handle::type_id::create({name, "_target"});
    target_h.kind = RDMA_RESOURCE_CMQ;
    target_h.function_uid = binding.function_uid;
    target_h.object_id = TEST_CMQ_ID;
    target_h.generation = binding.generation;
    body = rdma_cmq_sqe_model::type_id::create({name, "_body"});
    body.opcode = RDMA_CMQ_QUERY;
    body.command_id = longint'(marker) + 1'b1;
    body.function_h = binding.make_handle();
    body.target_h = target_h;
    body.flags = marker;
    command.body = body;
    command.qpc_signature_source = rdma_hw_image::type_id::create(
      {name, "_signature"}
    );
    command.qpc_signature_source.bytes.push_back(marker ^ 8'hff);
    command.qpc_signature_source.length = 1;
    command.qpc_signature_source.alignment = 1;
    command.qpc_signature_source.endian = RDMA_ENDIAN_LITTLE;
    command.qpc_signature_source.image_kind = RDMA_IMAGE_QPC;
    command.qpc_signature_source.hardware_version = 1;
    command.qpc_signature_source.function_generation = binding.generation;
    command.timeout = timeout_value;
    return command;
  endfunction

  // 功能：make_profile_hook_body 创建独立的 rdma_cmq_profile_hook_body；根据 name、binding、value 设置字段 body、body.value、body.nested_h、nested_h.kind、nested_h.function_uid、nested_h.object_id、nested_h.generation，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、binding（输入）、value（输入）；make_profile_hook_body 读取 name、binding、value 并使用字段 body、body.value、body.nested_h、nested_h.kind、nested_h.function_uid、nested_h.object_id、nested_h.generation；函数返回 rdma_cmq_profile_hook_body，不取得调用方资源所有权。
  // 失败/边界：make_profile_hook_body 的结果直接由 return body 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_cmq_profile_hook_body make_profile_hook_body(
    string name,
    rdma_function_binding binding,
    int unsigned value
  );
    rdma_cmq_profile_hook_body body;

    body = rdma_cmq_profile_hook_body::type_id::create(name);
    body.value = value;
    body.nested_h = rdma_handle::type_id::create({name, "_nested"});
    body.nested_h.kind = RDMA_RESOURCE_CMQ;
    body.nested_h.function_uid = binding.function_uid;
    body.nested_h.object_id = TEST_CMQ_ID;
    body.nested_h.generation = binding.generation;
    return body;
  endfunction

  // 功能：make_context_handle 创建独立的 rdma_handle；根据 name、binding、kind、object_id 设置字段 handle、handle.kind、handle.function_uid、handle.object_id、handle.generation，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、binding（输入）、kind（输入）、object_id（输入）；make_context_handle 读取 name、binding、kind、object_id 并使用字段 handle、handle.kind、handle.function_uid、handle.object_id、handle.generation；函数返回 rdma_handle，不取得调用方资源所有权。
  // 失败/边界：make_context_handle 的结果直接由 return handle 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_handle make_context_handle(
    string name,
    rdma_function_binding binding,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle handle;

    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.function_uid = binding.function_uid;
    handle.object_id = object_id;
    handle.generation = binding.generation;
    return handle;
  endfunction

  // 功能：make_qpc_context 创建独立的 rdma_qpc_model；根据 name、binding 设置字段 qpc、qpc.qp_h、qpc.pd_h、qpc.send_cq_h、qpc.recv_cq_h、qpc.transport、qpc.state、qpc.path_mtu_bytes、qpc.sq_depth、qpc.rq_depth，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、binding（输入）；make_qpc_context 读取 name、binding 并使用字段 qpc、qpc.qp_h、qpc.pd_h、qpc.send_cq_h、qpc.recv_cq_h、qpc.transport、qpc.state、qpc.path_mtu_bytes；函数返回 rdma_qpc_model，不取得调用方资源所有权。
  // 失败/边界：make_qpc_context 的结果直接由 return qpc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_qpc_model make_qpc_context(
    string name,
    rdma_function_binding binding
  );
    rdma_qpc_model qpc;
    rdma_qpc_rc_ext rc_ext;

    qpc = rdma_qpc_model::type_id::create(name);
    qpc.qp_h = make_context_handle({name, "_qp"}, binding,
                                   RDMA_RESOURCE_QP, 32'h101);
    qpc.pd_h = make_context_handle({name, "_pd"}, binding,
                                   RDMA_RESOURCE_PD, 32'h202);
    qpc.send_cq_h = make_context_handle({name, "_scq"}, binding,
                                        RDMA_RESOURCE_CQ, 32'h303);
    qpc.recv_cq_h = make_context_handle({name, "_rcq"}, binding,
                                        RDMA_RESOURCE_CQ, 32'h304);
    qpc.transport = RDMA_TRANSPORT_RC;
    qpc.state = RDMA_QPS_RTS;
    qpc.path_mtu_bytes = 1024;
    qpc.sq_depth = 64;
    qpc.rq_depth = 32;
    qpc.sq_backing.value = 64'h0000_0000_1000_0000;
    qpc.rq_backing.value = 64'h0000_0000_1100_0000;
    qpc.context_backing.value = 64'h0000_0000_1200_0000;
    rc_ext = rdma_qpc_rc_ext::type_id::create({name, "_rc_ext"});
    rc_ext.remote_qpn = 24'h654321;
    qpc.transport_ext = rc_ext;
    return qpc;
  endfunction

  // 功能：make_scalar_extension_qpc 创建独立的 rdma_cmq_scalar_extension_qpc；根据 name、binding、extension_value 设置字段 base_qpc、qpc、qpc.extension_value，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、binding（输入）、extension_value（输入）；make_scalar_extension_qpc 读取 name、binding、extension_value 并使用字段 base_qpc、qpc、qpc.extension_value；函数返回 rdma_cmq_scalar_extension_qpc，不取得调用方资源所有权。
  // 失败/边界：make_scalar_extension_qpc 的结果直接由 return qpc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_cmq_scalar_extension_qpc
      make_scalar_extension_qpc(
        string name,
        rdma_function_binding binding,
        int unsigned extension_value
      );
    rdma_qpc_model base_qpc;
    rdma_cmq_scalar_extension_qpc qpc;

    base_qpc = make_qpc_context({name, "_base"}, binding);
    qpc = rdma_cmq_scalar_extension_qpc::type_id::create(name);
    qpc.copy(base_qpc);
    qpc.extension_value = extension_value;
    return qpc;
  endfunction

  // 功能：make_edge_extension_qpc 创建独立的 rdma_cmq_edge_extension_qpc；根据 name、binding 设置字段 base_qpc、qpc、qpc.extension_h，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、binding（输入）；make_edge_extension_qpc 读取 name、binding 并使用字段 base_qpc、qpc、qpc.extension_h；函数返回 rdma_cmq_edge_extension_qpc，不取得调用方资源所有权。
  // 失败/边界：make_edge_extension_qpc 的结果直接由 return qpc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_cmq_edge_extension_qpc make_edge_extension_qpc(
    string name,
    rdma_function_binding binding
  );
    rdma_qpc_model base_qpc;
    rdma_cmq_edge_extension_qpc qpc;

    base_qpc = make_qpc_context({name, "_base"}, binding);
    qpc = rdma_cmq_edge_extension_qpc::type_id::create(name);
    qpc.copy(base_qpc);
    qpc.extension_h = make_context_handle(
      {name, "_extension"}, binding, RDMA_RESOURCE_CMQ, TEST_CMQ_ID
    );
    return qpc;
  endfunction

  // 功能：make_context_page_layout 创建独立的 rdma_page_table_layout；根据 name 设置字段 layout、layout.mode、sd_base.value、current_base.value、layout.current_valid、next_base.value、layout.next_valid，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_context_page_layout 读取 name 并使用字段 layout、layout.mode、sd_base.value、current_base.value、layout.current_valid、next_base.value、layout.next_valid；函数返回 rdma_page_table_layout，不取得调用方资源所有权。
  // 失败/边界：make_context_page_layout 的结果直接由 return layout 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_page_table_layout make_context_page_layout(
    string name
  );
    rdma_page_table_layout layout;

    layout = rdma_page_table_layout::type_id::create(name);
    layout.mode = RDMA_OBJECT_INDIRECT_4K;
    layout.sd_base.value = 64'h0000_0000_0100_0000;
    layout.current_base.value = 64'h0000_0000_0200_0000;
    layout.current_valid = 1'b1;
    layout.next_base.value = 64'h0000_0000_0300_0000;
    layout.next_valid = 1'b1;
    return layout;
  endfunction

  // 功能：make_context_ring 创建独立的 rdma_ring_position；根据 name、index 设置字段 ring、ring.index，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、index（输入）；make_context_ring 读取 name、index 并使用字段 ring、ring.index；函数返回 rdma_ring_position，不取得调用方资源所有权。
  // 失败/边界：make_context_ring 的结果直接由 return ring 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_ring_position make_context_ring(
    string name,
    int unsigned index
  );
    rdma_ring_position ring;

    ring = rdma_ring_position::type_id::create(name);
    ring.index = index;
    return ring;
  endfunction

  // 功能：make_cqc_context 创建独立的 rdma_cqc_model；根据 name、binding 设置字段 cqc、cqc.cq_h、cqc.ceq_h、cqc.state、cqc.depth、cqc.cqe_size_bytes、cqc.threshold、cqc.page_layout、cqc.producer、cqc.consumer，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、binding（输入）；make_cqc_context 读取 name、binding 并使用字段 cqc、cqc.cq_h、cqc.ceq_h、cqc.state、cqc.depth、cqc.cqe_size_bytes、cqc.threshold、cqc.page_layout；函数返回 rdma_cqc_model，不取得调用方资源所有权。
  // 失败/边界：make_cqc_context 的结果直接由 return cqc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_cqc_model make_cqc_context(
    string name,
    rdma_function_binding binding
  );
    rdma_cqc_model cqc;

    cqc = rdma_cqc_model::type_id::create(name);
    cqc.cq_h = make_context_handle({name, "_cq"}, binding,
                                   RDMA_RESOURCE_CQ, 32'h301);
    cqc.ceq_h = make_context_handle({name, "_ceq"}, binding,
                                    RDMA_RESOURCE_CEQ, 32'h701);
    cqc.state = RDMA_CONTEXT_VALID;
    cqc.depth = 64;
    cqc.cqe_size_bytes = 64;
    cqc.threshold = 8;
    cqc.page_layout = make_context_page_layout({name, "_layout"});
    cqc.producer = make_context_ring({name, "_producer"}, 9);
    cqc.consumer = make_context_ring({name, "_consumer"}, 3);
    cqc.shadow_backing.value = 64'h0000_0000_1300_0000;
    return cqc;
  endfunction

  // 功能：make_mrt_context 创建独立的 rdma_mrt_model；根据 name、binding 设置字段 mrt、mrt.mr_h、mrt.pd_h、mrt.state、iova.value、mrt.length、mrt.lkey、mrt.rkey、mrt.access、mrt.object_type，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、binding（输入）；make_mrt_context 读取 name、binding 并使用字段 mrt、mrt.mr_h、mrt.pd_h、mrt.state、iova.value、mrt.length、mrt.lkey、mrt.rkey；函数返回 rdma_mrt_model，不取得调用方资源所有权。
  // 失败/边界：make_mrt_context 的结果直接由 return mrt 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_mrt_model make_mrt_context(
    string name,
    rdma_function_binding binding
  );
    rdma_mrt_model mrt;

    mrt = rdma_mrt_model::type_id::create(name);
    mrt.mr_h = make_context_handle({name, "_mr"}, binding,
                                   RDMA_RESOURCE_MR, 32'h000123);
    mrt.pd_h = make_context_handle({name, "_pd"}, binding,
                                   RDMA_RESOURCE_PD, 32'h000202);
    mrt.state = RDMA_CONTEXT_VALID;
    mrt.iova.value = 64'h0000_0000_8000_0000;
    mrt.length = 64'h2000;
    mrt.lkey = 32'h0001_235a;
    mrt.rkey = mrt.lkey;
    mrt.access = '{local_write:1'b1, remote_read:1'b1,
                   remote_write:1'b1, memory_window_bind:1'b0,
                   remote_atomic:1'b0};
    mrt.object_type = 2'd1;
    mrt.page_layout.pba0.value = 64'h0000_0000_0400_0000;
    return mrt;
  endfunction

  // 功能：make_srqc_context 创建独立的 rdma_srqc_model；根据 name、binding 设置字段 srqc、srqc.srq_h、srqc.pd_h、srqc.state、srqc.depth、srqc.load_pi_threshold、srqc.limit_threshold、srfq_backing.value、shadow_backing.value、srqc.producer，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、binding（输入）；make_srqc_context 读取 name、binding 并使用字段 srqc、srqc.srq_h、srqc.pd_h、srqc.state、srqc.depth、srqc.load_pi_threshold、srqc.limit_threshold、srfq_backing.value；函数返回 rdma_srqc_model，不取得调用方资源所有权。
  // 失败/边界：make_srqc_context 的结果直接由 return srqc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_srqc_model make_srqc_context(
    string name,
    rdma_function_binding binding
  );
    rdma_srqc_model srqc;

    srqc = rdma_srqc_model::type_id::create(name);
    srqc.srq_h = make_context_handle({name, "_srq"}, binding,
                                     RDMA_RESOURCE_SRQ, 32'h501);
    srqc.pd_h = make_context_handle({name, "_pd"}, binding,
                                    RDMA_RESOURCE_PD, 32'h202);
    srqc.state = RDMA_CONTEXT_VALID;
    srqc.depth = 32;
    srqc.load_pi_threshold = 4;
    srqc.limit_threshold = 8;
    srqc.srfq_backing.value = 64'h0000_0000_1400_0000;
    srqc.shadow_backing.value = 64'h0000_0000_1500_0000;
    srqc.producer = make_context_ring({name, "_producer"}, 5);
    return srqc;
  endfunction

  // 功能：make_ceqc_context 创建独立的 rdma_ceqc_model；根据 name、binding 设置字段 ceqc、ceqc.ceq_h、ceqc.state、ceqc.depth、ceqc.vector_id、ceqc.page_layout、ceqc.producer、ceqc.consumer，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、binding（输入）；make_ceqc_context 读取 name、binding 并使用字段 ceqc、ceqc.ceq_h、ceqc.state、ceqc.depth、ceqc.vector_id、ceqc.page_layout、ceqc.producer、ceqc.consumer；函数返回 rdma_ceqc_model，不取得调用方资源所有权。
  // 失败/边界：make_ceqc_context 的结果直接由 return ceqc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_ceqc_model make_ceqc_context(
    string name,
    rdma_function_binding binding
  );
    rdma_ceqc_model ceqc;

    ceqc = rdma_ceqc_model::type_id::create(name);
    ceqc.ceq_h = make_context_handle({name, "_ceq"}, binding,
                                     RDMA_RESOURCE_CEQ, 32'h701);
    ceqc.state = RDMA_CONTEXT_VALID;
    ceqc.depth = 32;
    ceqc.vector_id = 11;
    ceqc.page_layout = make_context_page_layout({name, "_layout"});
    ceqc.producer = make_context_ring({name, "_producer"}, 7);
    ceqc.consumer = make_context_ring({name, "_consumer"}, 2);
    return ceqc;
  endfunction

  // 功能：make_aeqc_context 创建独立的 rdma_aeqc_model；根据 name、binding 设置字段 aeqc、aeqc.aeq_h、aeqc.state、aeqc.depth、aeqc.vector_id、aeqc.page_layout、aeqc.producer、aeqc.consumer，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、binding（输入）；make_aeqc_context 读取 name、binding 并使用字段 aeqc、aeqc.aeq_h、aeqc.state、aeqc.depth、aeqc.vector_id、aeqc.page_layout、aeqc.producer、aeqc.consumer；函数返回 rdma_aeqc_model，不取得调用方资源所有权。
  // 失败/边界：make_aeqc_context 的结果直接由 return aeqc 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_aeqc_model make_aeqc_context(
    string name,
    rdma_function_binding binding
  );
    rdma_aeqc_model aeqc;

    aeqc = rdma_aeqc_model::type_id::create(name);
    aeqc.aeq_h = make_context_handle({name, "_aeq"}, binding,
                                     RDMA_RESOURCE_AEQ, 32'h801);
    aeqc.state = RDMA_CONTEXT_VALID;
    aeqc.depth = 32;
    aeqc.vector_id = 12;
    aeqc.page_layout = make_context_page_layout({name, "_layout"});
    aeqc.producer = make_context_ring({name, "_producer"}, 8);
    aeqc.consumer = make_context_ring({name, "_consumer"}, 1);
    return aeqc;
  endfunction

  // 功能：在 rdma_cmq_engine_test 中，clear_submit_observation 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：mem（输入）、pcie（输入）、trace（输入）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_submit_observation 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  function automatic void clear_submit_observation(
    rdma_mock_host_mem mem,
    rdma_mock_pcie pcie,
    rdma_mock_call_trace trace
  );
    mem.calls.delete();
    pcie.calls.delete();
    trace.clear();
  endfunction

  // 功能：在 rdma_cmq_engine_test 中，expect_submit_trace 在测试中执行 expect_submit_trace 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、trace（输入）、expected（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_submit_trace 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_submit_trace(
    string label,
    rdma_mock_call_trace trace,
    string expected[]
  );
    if (trace.calls.size() != expected.size()) begin
      `uvm_error(label,
                 $sformatf("trace has %0d calls, expected %0d",
                           trace.calls.size(), expected.size()))
      return;
    end
    foreach (expected[i]) begin
      if (trace.calls[i] != expected[i])
        `uvm_error(label,
                   $sformatf("trace[%0d] is %s, expected %s", i,
                             trace.calls[i], expected[i]))
    end
  endfunction

  // 功能：在 rdma_cmq_engine_test 中，expect_no_submit_side_effects 在测试中执行 expect_no_submit_side_effects 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、mem（输入）、pcie（输入）、trace（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_no_submit_side_effects 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_no_submit_side_effects(
    string label,
    rdma_mock_host_mem mem,
    rdma_mock_pcie pcie,
    rdma_mock_call_trace trace
  );
    if (mem.calls.size() != 0 || pcie.calls.size() != 0 ||
        trace.calls.size() != 0)
      `uvm_error(label, "submission rejection caused adapter side effects")
  endfunction

  // 功能：在 rdma_cmq_engine_test 中，prepare_active 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：label（输入）、engine（输入）、mem（输入）、pcie（输入）、scheduler（输入）、profile（输入）、prepared_binding（输入）、active_binding（输入）、cmq（输入）、runtime_desc（输出）；prepare_active 驱动下游事务，并写入 runtime_desc；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：prepare_active 失败或超时通过 runtime_desc 明确发布；该路径不隐式重试，也不转移未声明资源。
  task automatic prepare_active(
    string label,
    rdma_cmq_engine engine,
    rdma_mock_host_mem mem,
    rdma_mock_pcie pcie,
    rdma_doorbell_scheduler scheduler,
    rdma_cmq_test_profile profile,
    rdma_function_binding prepared_binding,
    rdma_function_binding active_binding,
    rdma_cmq cmq,
    output rdma_cmq_runtime_desc runtime_desc
  );
    rdma_status status;

    status = scheduler.configure(mem, pcie);
    expect_status({label, "_SCHEDULER"}, status, RDMA_SC_OK);
    engine.prepare(prepared_binding, cmq, 1'b1, 20'h34567, mem,
                   scheduler, profile, runtime_desc, status);
    expect_status({label, "_PREPARE"}, status, RDMA_SC_OK);
    engine.activate(active_binding, status);
    expect_status({label, "_ACTIVATE"}, status, RDMA_SC_OK);
  endtask

  // 功能：判断 count_host_calls 对应的状态、能力或账本条件，并返回确定的布尔/计数结果，不修改状态。
  // 输入/输出及副作用：mem（输入）、method_name（输入）；count_host_calls 读取 mem、method_name 并使用字段 result；函数返回 int unsigned，不取得调用方资源所有权。
  // 失败/边界：count_host_calls 只读取现有账本；输入未初始化时返回保守结果，不得借助默认 Function/root 猜测。
  function automatic int unsigned count_host_calls(
    rdma_mock_host_mem mem,
    string method_name
  );
    int unsigned result;

    result = 0;
    foreach (mem.calls[i]) begin
      if (mem.calls[i].method_name == method_name)
        result++;
    end
    return result;
  endfunction

  // 功能：host_call_index 使用 mem、method_name、ordinal 在对应表、队列或账本中查找唯一条目，并返回下标、对象或查找状态。
  // 输入/输出及副作用：mem（输入）、method_name（输入）、ordinal（输入）；host_call_index 读取 mem、method_name、ordinal 并使用字段 match_count；函数返回 int，不取得调用方资源所有权。
  // 失败/边界：host_call_index 查找未命中时返回 -1；该路径不隐式重试，也不转移未声明资源。
  function automatic int host_call_index(
    rdma_mock_host_mem mem,
    string method_name,
    int unsigned ordinal
  );
    int unsigned match_count;

    match_count = 0;
    foreach (mem.calls[i]) begin
      if (mem.calls[i].method_name != method_name)
        continue;
      if (match_count == ordinal)
        return i;
      match_count++;
    end
    return -1;
  endfunction

  // 功能：在 rdma_cmq_engine_test 中，write_profile_cqe 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：label（输入）、mem（输入）、mapping（输入）、profile（输入）、cq_sequence（输入）、owner（输入）、ticket（输入）、hardware_ecode（输入）、raw_cqe（输出）；输入
  //   request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：write_profile_cqe 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  task automatic write_profile_cqe(
    string label,
    rdma_mock_host_mem mem,
    rdma_dma_mapping mapping,
    rdma_cmq_test_profile profile,
    longint unsigned cq_sequence,
    bit owner,
    rdma_cmq_ticket ticket,
    bit [31:0] hardware_ecode,
    output rdma_hw_image raw_cqe
  );
    byte data[];
    rdma_status status;

    raw_cqe = null;
    if (mem == null || mapping == null || profile == null ||
        ticket == null || ticket.function_h == null ||
        ticket.opcode_key == null) begin
      `uvm_error(label, "CQE write prerequisites are incomplete")
      return;
    end
    raw_cqe = profile.make_cqe(
      {label, "_raw_cqe"}, owner, ticket.opcode_key.opcode,
      hardware_ecode, ticket.sq_index, ticket.sq_wrap,
      ticket.function_h.generation
    );
    if (raw_cqe == null || raw_cqe.bytes.size() != 64) begin
      `uvm_error(label, "profile did not produce a 64-byte CQE")
      raw_cqe = null;
      return;
    end
    data = new[64];
    foreach (data[i])
      data[i] = raw_cqe.bytes[i];
    status = mem.write(
      mapping,
      TEST_CQ_OFFSET + ((cq_sequence % 32) * 64),
      data
    );
    expect_status({label, "_WRITE"}, status, RDMA_SC_OK);
  endtask

  // 功能：在 rdma_cmq_engine_test 中，overwrite_profile_cqe 配置测试 fixture 的定向故障或替代依赖，使下一次调用覆盖指定边界路径。
  // 输入/输出及副作用：label（输入）、mem（输入）、mapping（输入）、cq_sequence（输入）、raw_cqe（输入）；overwrite_profile_cqe 驱动下游事务；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：overwrite_profile_cqe 异常完成由下游接口或 UVM 报告机制发布；该路径不隐式重试，也不转移未声明资源。
  task automatic overwrite_profile_cqe(
    string label,
    rdma_mock_host_mem mem,
    rdma_dma_mapping mapping,
    longint unsigned cq_sequence,
    rdma_hw_image raw_cqe
  );
    byte data[];
    rdma_status status;

    if (mem == null || mapping == null || raw_cqe == null ||
        raw_cqe.bytes.size() != 64) begin
      `uvm_error(label, "raw CQE overwrite prerequisites are incomplete")
      return;
    end
    data = new[64];
    foreach (data[i])
      data[i] = raw_cqe.bytes[i];
    status = mem.write(
      mapping,
      TEST_CQ_OFFSET + ((cq_sequence % 32) * 64),
      data
    );
    expect_status({label, "_WRITE"}, status, RDMA_SC_OK);
  endtask

  // 功能：在 rdma_cmq_engine_test 中，expect_poll_read_geometry 在测试中执行 expect_poll_read_geometry 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、mem（输入）、first_cq_sequence（输入）、expected_count（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM
  //   assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_poll_read_geometry 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_poll_read_geometry(
    string label,
    rdma_mock_host_mem mem,
    longint unsigned first_cq_sequence,
    int unsigned expected_count
  );
    int call_index;
    longint unsigned expected_offset;

    if (count_host_calls(mem, "read") != expected_count) begin
      `uvm_error(label,
                 $sformatf("poll issued %0d reads, expected %0d",
                           count_host_calls(mem, "read"),
                           expected_count))
      return;
    end
    for (int unsigned i = 0; i < expected_count; i++) begin
      call_index = host_call_index(mem, "read", i);
      expected_offset = TEST_CQ_OFFSET +
                        (((first_cq_sequence + i) % 32) * 64);
      if (call_index < 0 || mem.calls[call_index].size != 64 ||
          mem.calls[call_index].offset != expected_offset)
        `uvm_error(label,
                   $sformatf("read %0d was not an exact 64B CQ slot read",
                             i))
    end
  endfunction

  // 功能：在 rdma_cmq_engine_test 中，expect_empty_poll_without_read 在测试中执行 expect_empty_poll_without_read 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、engine（输入）、mem（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_empty_poll_without_read 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  task automatic expect_empty_poll_without_read(
    string label,
    rdma_cmq_engine_probe engine,
    rdma_mock_host_mem mem
  );
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_status status;
    longint unsigned before_publish;
    longint unsigned before_retire;
    longint unsigned before_consume;

    before_publish = engine.published_count();
    before_retire = engine.retired_count();
    before_consume = engine.cq_consumed_count();
    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status({label, "_STATUS"}, status, RDMA_SC_OK);
    if (completions.size() != 0 || diagnostics.size() != 0 ||
        count_host_calls(mem, "read") != 0 ||
        engine.state() != RDMA_CMQ_ENGINE_ACTIVE ||
        engine.published_count() != before_publish ||
        engine.retired_count() != before_retire ||
        engine.cq_consumed_count() != before_consume ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0 ||
        engine.terminal_fifo_count() != 0)
      `uvm_error(label, "empty poll changed authority or read host memory")
  endtask

  // 功能：在 rdma_cmq_engine_test 中，expect_empty_poll_with_read 在测试中执行 expect_empty_poll_with_read 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、engine（输入）、mem（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_empty_poll_with_read 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  task automatic expect_empty_poll_with_read(
    string label,
    rdma_cmq_engine_probe engine,
    rdma_mock_host_mem mem
  );
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_status status;
    longint unsigned before_publish;
    longint unsigned before_retire;
    longint unsigned before_consume;

    before_publish = engine.published_count();
    before_retire = engine.retired_count();
    before_consume = engine.cq_consumed_count();
    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status({label, "_STATUS"}, status, RDMA_SC_OK);
    if (completions.size() != 0 || diagnostics.size() != 0 ||
        count_host_calls(mem, "read") != 1 ||
        engine.state() != RDMA_CMQ_ENGINE_ACTIVE ||
        engine.published_count() != before_publish ||
        engine.retired_count() != before_retire ||
        engine.cq_consumed_count() != before_consume ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0 ||
        engine.terminal_fifo_count() != 0)
      `uvm_error(label,
                 "formatted empty poll changed authority or missed CQ read")
    expect_poll_read_geometry({label, "_READ"}, mem, before_consume, 1);
  endtask

  // 功能：在 rdma_cmq_engine_test 中，expect_inconsistent_empty_poll_without_read 在测试中执行 expect_inconsistent_empty_poll_without_read 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、engine（输入）、mem（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_inconsistent_empty_poll_without_read 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  task automatic expect_inconsistent_empty_poll_without_read(
    string label,
    rdma_cmq_engine_probe engine,
    rdma_mock_host_mem mem
  );
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_status status;

    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status({label, "_STATUS"}, status, RDMA_SC_INVALID_STATE);
    if (completions.size() != 0 || diagnostics.size() != 0 ||
        count_host_calls(mem, "read") != 0 ||
        engine.state() != RDMA_CMQ_ENGINE_POISONED ||
        engine.last_poison_snapshot() != null)
      `uvm_error(
        label,
        "inconsistent empty ledger did not fail closed before host access"
      )
  endtask

  // 功能：在 rdma_cmq_engine_test 中，expect_polled_completion 在测试中执行 expect_polled_completion 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、engine（输入）、completion（输入）、expected_ticket（输入）、expected_raw（输入）、expected_owner（输入）、expected_hardware_ecode（输入）、expected_code（输入）；fixture/输入由测试调用方提供；执行时会产生
  //   UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_polled_completion 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_polled_completion(
    string label,
    rdma_cmq_engine_probe engine,
    rdma_cmq_completion completion,
    rdma_cmq_ticket expected_ticket,
    rdma_hw_image expected_raw,
    bit expected_owner,
    bit [31:0] expected_hardware_ecode,
    rdma_status_code_e expected_code
  );
    rdma_hw_cmq_completion payload;
    rdma_status validation_status;

    if (completion == null || expected_ticket == null ||
        expected_ticket.function_h == null ||
        expected_ticket.cmq_h == null ||
        expected_ticket.opcode_key == null || expected_raw == null) begin
      `uvm_error(label, "completion comparison prerequisites are null")
      return;
    end
    validation_status = completion.validate();
    expect_status({label, "_VALIDATE"}, validation_status, RDMA_SC_OK);
    if (completion.ticket == null || completion.ticket == expected_ticket ||
        completion.ticket.function_h == expected_ticket.function_h ||
        completion.ticket.cmq_h == expected_ticket.cmq_h ||
        completion.ticket.opcode_key == expected_ticket.opcode_key ||
        completion.ticket.command_id != expected_ticket.command_id ||
        completion.ticket.slot_sequence != expected_ticket.slot_sequence ||
        completion.ticket.sq_index != expected_ticket.sq_index ||
        completion.ticket.sq_wrap != expected_ticket.sq_wrap ||
        completion.ticket.opcode_key.opcode !=
          expected_ticket.opcode_key.opcode)
      `uvm_error(label, "completion ticket is aliased or mismatched")
    expect_status({label, "_COMMAND_STATUS"}, completion.status,
                  expected_code);
    if (completion.status == null)
      return;
    if (completion.status.source_engine != RDMA_ENGINE_CMQ ||
        completion.status.function_uid !=
          expected_ticket.function_h.function_uid ||
        completion.status.generation !=
          expected_ticket.function_h.generation ||
        completion.status.resource_id != expected_ticket.cmq_h.object_id ||
        completion.status.command_id != expected_ticket.command_id)
      `uvm_error(label, "completion status identity is incomplete")
    if (expected_hardware_ecode == 0) begin
      if (completion.status.hardware_code_valid ||
          completion.status.hardware_code != 0)
        `uvm_error(label, "successful completion retained hardware error")
    end
    else if (!completion.status.hardware_code_valid ||
             completion.status.hardware_code != expected_hardware_ecode)
      `uvm_error(label, "completion lost the raw hardware ecode")
    if (completion.raw_cqe == null || completion.raw_cqe == expected_raw ||
        !engine.probe_same_image(completion.raw_cqe, expected_raw))
      `uvm_error(label, "completion raw CQE is aliased or mismatched")
    if (completion.raw_cqe != null &&
        (completion.raw_cqe.endian != expected_raw.endian ||
         completion.raw_cqe.hardware_version !=
           expected_raw.hardware_version))
      `uvm_error(label,
                 "completion raw CQE lost profile-wide format metadata")
    if (!$cast(payload, completion.decoded_response))
      `uvm_error(label, "completion lost the typed decoded payload")
    else if (payload.owner != expected_owner ||
             payload.opcode != expected_ticket.opcode_key.opcode[7:0] ||
             payload.command_ecode != expected_hardware_ecode[7:0] ||
             payload.wqe_index != expected_ticket.sq_index ||
             payload.wrap != expected_ticket.sq_wrap)
      `uvm_error(label, "decoded CQE payload fields are mismatched")
  endfunction

  // 功能：在 rdma_cmq_engine_test 中，expect_timeout_completion 在测试中执行 expect_timeout_completion 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、completion（输入）、expected_ticket（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT
  //   转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_timeout_completion 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_timeout_completion(
    string label,
    rdma_cmq_completion completion,
    rdma_cmq_ticket expected_ticket
  );
    rdma_status validation_status;

    if (completion == null || expected_ticket == null ||
        expected_ticket.function_h == null ||
        expected_ticket.cmq_h == null ||
        expected_ticket.opcode_key == null) begin
      `uvm_error(label, "timeout completion prerequisites are null")
      return;
    end
    validation_status = completion.validate();
    expect_status({label, "_VALIDATE"}, validation_status, RDMA_SC_OK);
    if (completion.ticket == null || completion.ticket == expected_ticket ||
        completion.ticket.function_h == expected_ticket.function_h ||
        completion.ticket.cmq_h == expected_ticket.cmq_h ||
        completion.ticket.opcode_key == expected_ticket.opcode_key ||
        completion.ticket.command_id != expected_ticket.command_id ||
        completion.ticket.slot_sequence != expected_ticket.slot_sequence ||
        completion.ticket.sq_index != expected_ticket.sq_index ||
        completion.ticket.sq_wrap != expected_ticket.sq_wrap ||
        completion.ticket.absolute_deadline !=
          expected_ticket.absolute_deadline)
      `uvm_error(label, "timeout completion ticket is aliased or mismatched")
    expect_status({label, "_STATUS"}, completion.status, RDMA_SC_TIMEOUT);
    if (completion.status == null)
      return;
    if (completion.status.source_engine != RDMA_ENGINE_CMQ ||
        completion.status.function_uid !=
          expected_ticket.function_h.function_uid ||
        completion.status.generation !=
          expected_ticket.function_h.generation ||
        completion.status.resource_id != expected_ticket.cmq_h.object_id ||
        completion.status.command_id != expected_ticket.command_id ||
        completion.raw_cqe != null || completion.decoded_response != null)
      `uvm_error(label, "timeout completion identity or payload is invalid")
  endfunction

  // 功能：在 rdma_cmq_engine_test 中，expect_late_diagnostic 在测试中执行 expect_late_diagnostic 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、engine（输入）、diagnostic（输入）、expected_ticket（输入）、expected_raw（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM
  //   assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_late_diagnostic 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_late_diagnostic(
    string label,
    rdma_cmq_engine_probe engine,
    rdma_cmq_diagnostic diagnostic,
    rdma_cmq_ticket expected_ticket,
    rdma_hw_image expected_raw
  );
    rdma_status validation_status;

    if (diagnostic == null || expected_ticket == null ||
        expected_ticket.function_h == null ||
        expected_ticket.cmq_h == null ||
        expected_ticket.opcode_key == null || expected_raw == null) begin
      `uvm_error(label, "late diagnostic prerequisites are null")
      return;
    end
    validation_status = diagnostic.validate();
    expect_status({label, "_VALIDATE"}, validation_status, RDMA_SC_OK);
    if (diagnostic.kind != RDMA_CMQ_DIAG_LATE_COMPLETION ||
        diagnostic.ticket == null || diagnostic.ticket == expected_ticket ||
        diagnostic.ticket.function_h == expected_ticket.function_h ||
        diagnostic.ticket.cmq_h == expected_ticket.cmq_h ||
        diagnostic.ticket.opcode_key == expected_ticket.opcode_key ||
        diagnostic.ticket.command_id != expected_ticket.command_id ||
        diagnostic.ticket.slot_sequence != expected_ticket.slot_sequence ||
        diagnostic.ticket.sq_index != expected_ticket.sq_index ||
        diagnostic.ticket.sq_wrap != expected_ticket.sq_wrap ||
        diagnostic.ticket.absolute_deadline != expected_ticket.absolute_deadline)
      `uvm_error(label, "late diagnostic ticket is aliased or mismatched")
    expect_status({label, "_STATUS"}, diagnostic.status, RDMA_SC_TIMEOUT);
    if (diagnostic.status == null)
      return;
    if (diagnostic.status.source_engine != RDMA_ENGINE_CMQ ||
        diagnostic.status.function_uid !=
          expected_ticket.function_h.function_uid ||
        diagnostic.status.generation !=
          expected_ticket.function_h.generation ||
        diagnostic.status.resource_id != expected_ticket.cmq_h.object_id ||
        diagnostic.status.command_id != expected_ticket.command_id ||
        diagnostic.raw_cqe == null || diagnostic.raw_cqe == expected_raw ||
        !engine.probe_same_image(diagnostic.raw_cqe, expected_raw))
      `uvm_error(label, "late diagnostic identity or raw CQE is invalid")
  endfunction

  // 功能：在 rdma_cmq_engine_test 中，expect_poison_diagnostic 在测试中执行 expect_poison_diagnostic 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、engine（输入）、diagnostic（输入）、expected_kind（输入）、expected_ticket（输入）、expected_raw（输入）、expected_binding（输入）、expected_cmq（输入）；fixture/输入由测试调用方提供；执行时会产生
  //   UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_poison_diagnostic 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_poison_diagnostic(
    string label,
    rdma_cmq_engine_probe engine,
    rdma_cmq_diagnostic diagnostic,
    rdma_cmq_diagnostic_kind_e expected_kind,
    rdma_cmq_ticket expected_ticket,
    rdma_hw_image expected_raw,
    rdma_function_binding expected_binding,
    rdma_cmq expected_cmq
  );
    rdma_status validation_status;

    if (diagnostic == null || engine == null || expected_raw == null ||
        expected_binding == null || expected_cmq == null ||
        expected_cmq.handle == null) begin
      `uvm_error(label, "poison diagnostic prerequisites are null")
      return;
    end
    validation_status = diagnostic.validate();
    expect_status({label, "_VALIDATE"}, validation_status, RDMA_SC_OK);
    if (diagnostic.kind != expected_kind)
      `uvm_error(label, $sformatf(
        "expected diagnostic kind %s, got %s",
        expected_kind.name(), diagnostic.kind.name()
      ))
    if (expected_ticket == null) begin
      if (diagnostic.ticket != null)
        `uvm_error(label, "untrusted CQE diagnostic leaked a ticket")
    end
    else if (diagnostic.ticket == null ||
             diagnostic.ticket == expected_ticket ||
             diagnostic.ticket.function_h == expected_ticket.function_h ||
             diagnostic.ticket.cmq_h == expected_ticket.cmq_h ||
             diagnostic.ticket.opcode_key == expected_ticket.opcode_key ||
             diagnostic.ticket.command_id != expected_ticket.command_id ||
             diagnostic.ticket.slot_sequence !=
               expected_ticket.slot_sequence ||
             diagnostic.ticket.sq_index != expected_ticket.sq_index ||
             diagnostic.ticket.sq_wrap != expected_ticket.sq_wrap)
      `uvm_error(label, "trusted CQE diagnostic ticket is aliased or wrong")
    expect_status({label, "_STATUS"}, diagnostic.status,
                  RDMA_SC_CODEC_ERROR);
    if (diagnostic.status != null &&
        (diagnostic.status.source_engine != RDMA_ENGINE_CMQ ||
         diagnostic.status.function_uid != expected_binding.function_uid ||
         diagnostic.status.generation != expected_binding.generation ||
         diagnostic.status.resource_id != expected_cmq.handle.object_id ||
         diagnostic.status.command_id !=
           ((expected_ticket == null) ? 0 : expected_ticket.command_id)))
      `uvm_error(label, "poison diagnostic status lost command identity")
    if (diagnostic.raw_cqe == null ||
        diagnostic.raw_cqe == expected_raw ||
        diagnostic.raw_cqe.bytes.size() != 64 ||
        !engine.probe_same_image(diagnostic.raw_cqe, expected_raw))
      `uvm_error(label, "poison diagnostic lost detached 64-byte evidence")
  endfunction

  // 功能：在 rdma_cmq_engine_test 中，expect_release_retry_identity 在测试中执行 expect_release_retry_identity 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、mem（输入）、retained_mapping（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT
  //   转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_release_retry_identity 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_release_retry_identity(
    string label,
    rdma_mock_host_mem mem,
    rdma_mock_dma_mapping retained_mapping
  );
    int first_index;
    int second_index;
    rdma_mock_dma_mapping first_release_mapping;
    rdma_mock_dma_mapping second_release_mapping;

    first_index = host_call_index(mem, "release", 0);
    second_index = host_call_index(mem, "release", 1);
    if (first_index < 0 || second_index < 0) begin
      `uvm_error(label, "two release records were not available")
      return;
    end
    if (!$cast(first_release_mapping, mem.calls[first_index].mapping) ||
        !$cast(second_release_mapping, mem.calls[second_index].mapping)) begin
      `uvm_error(label, "release record lost allocation identity")
      return;
    end
    if (retained_mapping == null ||
        !first_release_mapping.same_allocation(second_release_mapping) ||
        !retained_mapping.same_allocation(second_release_mapping))
      `uvm_error(label, "release retry changed mapping allocation identity")
  endfunction

  // 功能：在 rdma_cmq_engine_test 中由 same_nullable_handle 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_nullable_handle 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  function automatic bit same_nullable_handle(
    rdma_handle lhs,
    rdma_handle rhs
  );
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    return lhs.same_instance(rhs);
  endfunction

  // 功能：在 rdma_cmq_engine_test 中由 same_mapping_fields 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_mapping_fields 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  function automatic bit same_mapping_fields(
    rdma_dma_mapping lhs,
    rdma_dma_mapping rhs
  );
    if (lhs == null || rhs == null)
      return lhs == null && rhs == null;
    return same_nullable_handle(lhs.function_h, rhs.function_h) &&
           lhs.requester_bdf == rhs.requester_bdf &&
           lhs.pasid_valid == rhs.pasid_valid && lhs.pasid == rhs.pasid &&
           lhs.dma_domain_valid == rhs.dma_domain_valid &&
           lhs.dma_domain_id == rhs.dma_domain_id &&
           lhs.route == rhs.route && lhs.reset_epoch == rhs.reset_epoch &&
           lhs.route_valid == rhs.route_valid &&
           lhs.epoch_valid == rhs.epoch_valid &&
           lhs.backing_addr == rhs.backing_addr && lhs.iova == rhs.iova &&
           lhs.size == rhs.size && lhs.direction == rhs.direction &&
           lhs.permissions == rhs.permissions && lhs.state == rhs.state &&
           same_nullable_handle(lhs.owner_h, rhs.owner_h) &&
           lhs.umem_ref == rhs.umem_ref && lhs.pbl_ref == rhs.pbl_ref &&
           lhs.mw_ref == rhs.mw_ref && lhs.umem_backed == rhs.umem_backed &&
           lhs.umem_page_count == rhs.umem_page_count;
  endfunction

  // 功能：断言 prepare 在 allocation 后失败时未发布 runtime，且只释放一次 backing。
  // 输入/输出及副作用：label 标识报告；engine/mem/runtime_desc 为失败后的 fixture，
  //   expected_write_count 给出允许的 write 次数；仅发布 UVM_ERROR。
  // 失败/边界：runtime 非空、allocate/write/release 计数错误、region 未标为 RELEASED，
  //   或 engine 未回到 UNCONFIGURED 时报告错误；不再次释放测试资源。
  function automatic void expect_post_allocate_rollback(
    string label,
    rdma_cmq_engine engine,
    rdma_mock_host_mem mem,
    rdma_cmq_runtime_desc runtime_desc,
    int unsigned expected_write_count
  );
    int unsigned release_count;

    release_count = count_host_calls(mem, "release") +
                    count_host_calls(mem, "release_opaque");
    if (runtime_desc != null)
      `uvm_error(label, "failed prepare published a runtime descriptor")
    if (count_host_calls(mem, "allocate") != 1 ||
        count_host_calls(mem, "write") != expected_write_count ||
        release_count != 1)
      `uvm_error(label,
                 "post-allocation failure did not release exactly once")
    if (mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error(label, "post-allocation failure leaked its mock region")
    expect_unconfigured({label, "_STATE"}, engine);
  endfunction

  // 功能：断言 CMQ engine 处于 UNCONFIGURED 且不再暴露 backing mapping。
  // 输入/输出及副作用：label 标识报告，engine 为只读测试对象；仅发布 UVM_ERROR。
  // 失败/边界：状态或 mapping 任一残留即分别报错；调用方须提供非空 engine。
  function automatic void expect_unconfigured(
    string label,
    rdma_cmq_engine engine
  );
    if (engine.state() != RDMA_CMQ_ENGINE_UNCONFIGURED)
      `uvm_error(label, "engine did not remain UNCONFIGURED")
    if (engine.mapping_snapshot() != null)
      `uvm_error(label, "unconfigured engine retained a mapping")
  endfunction

  // 功能：用统一 BAR=1、offset=20'h34567 参数调用 engine.prepare 并断言成功。
  // 输入/输出及副作用：label 与全部 prepare 依赖为输入；runtime_desc 输出 DUT 发布值；
  //   会分配/初始化 mock backing，并通过 expect_status 发布断言结果。
  // 失败/边界：依赖为空或 prepare 拒绝时 status 断言报错，runtime_desc 保留 DUT 输出；
  //   helper 不重试、不 reset，也不接管 mem/scheduler/profile 生命周期。
  task automatic prepare_defaults(
    string label,
    rdma_cmq_engine engine,
    rdma_mock_host_mem mem,
    rdma_function_binding binding,
    rdma_cmq cmq,
    rdma_doorbell_scheduler scheduler,
    rdma_cmq_test_profile profile,
    output rdma_cmq_runtime_desc runtime_desc
  );
    rdma_status status;

    engine.prepare(binding, cmq, 1'b1, 20'h34567, mem, scheduler,
                   profile, runtime_desc, status);
    expect_status(label, status, RDMA_SC_OK);
  endtask

  // 功能：构造覆盖 same_incarnation 全字段的 VF identity，供 exact batch-key 测试。
  // 输入/输出及副作用：name 仅命名返回对象；按 Task 13 literal 填充 route/UID/epoch。
  // 失败/边界：fixture 固定为合法 VF route；若公共 route 规则变化，调用测试会显式报错。
  function automatic rdma_function_identity make_journal_vf_identity(
    string name
  );
    rdma_function_identity identity;

    identity = new(name);
    identity.key.root_id = 16'h1234;
    identity.key.host_topology_key = 32'h89ab_cdef;
    identity.key.function_kind = RDMA_FUNCTION_VF;
    identity.key.parent_pf_bdf = '{
      segment:16'h2468, bus:8'h9a, device:5'h1b, function_num:3'h2
    };
    identity.key.vf_index = 16'h1357;
    identity.key.bdf = '{
      segment:16'h2468, bus:8'hbc, device:5'h1c, function_num:3'h5
    };
    identity.global_function_id = 32'hdead_beef;
    identity.function_uid = 64'h0123_4567_89ab_cdef;
    identity.generation = 32'h89ab_cdef;
    identity.reset_epoch = 64'hfedc_ba98_7654_3210;
    return identity;
  endfunction

  // 功能：直接复制完整 Function identity，供单字段 variation 构造独立输入。
  // 输入/输出及副作用：name/source 为输入；返回 detached value，不修改 source。
  // 失败/边界：source=null 时返回 null；本 helper 不替测试调用方隐藏 validate 失败。
  function automatic rdma_function_identity copy_journal_identity(
    string name,
    rdma_function_identity source
  );
    rdma_function_identity identity;

    if (source == null)
      return null;
    identity = new(name);
    identity.key = source.key;
    identity.global_function_id = source.global_function_id;
    identity.function_uid = source.function_uid;
    identity.generation = source.generation;
    identity.reset_epoch = source.reset_epoch;
    return identity;
  endfunction

  // 功能：直接构造属于 identity 的资源 handle，供 journal graph fixture 复用。
  // 输入/输出及副作用：name/kind/identity/object_id 为输入；返回新 base handle。
  // 失败/边界：identity=null 时返回 null；kind/object_id 的业务合法性由消费者验证。
  function automatic rdma_handle make_journal_handle(
    string name,
    rdma_resource_kind_e kind,
    rdma_function_identity identity,
    int unsigned object_id
  );
    rdma_handle handle;

    if (identity == null)
      return null;
    handle = new(name);
    handle.kind = kind;
    handle.function_uid = identity.function_uid;
    handle.object_id = object_id;
    handle.generation = identity.generation;
    return handle;
  endfunction

  // 功能：直接构造 Function handle，完整投影 identity 的 UID/global-ID/generation。
  // 输入/输出及副作用：name/identity 为输入；返回新 rdma_function_handle。
  // 失败/边界：identity=null 时返回 null；不把 route 或 reset epoch 塞进 handle。
  function automatic rdma_function_handle make_journal_function_handle(
    string name,
    rdma_function_identity identity
  );
    rdma_function_handle handle;

    if (identity == null)
      return null;
    handle = new(name);
    handle.kind = RDMA_RESOURCE_FUNCTION;
    handle.function_uid = identity.function_uid;
    handle.object_id = identity.global_function_id;
    handle.generation = identity.generation;
    return handle;
  endfunction

  // 功能：构造 canonical digest 与 completion shell 使用的确定性 hardware image。
  // 输入/输出及副作用：kind/target/generation/marker/length 决定 metadata 和 bytes；
  //   返回对象由调用方拥有，不写 Host-memory。
  // 失败/边界：length==0 仍返回畸形 fixture，由调用场景决定是否故意拒绝。
  function automatic rdma_hw_image make_journal_image(
    string name,
    rdma_image_kind_e image_kind,
    rdma_hw_target_kind_e target_kind,
    int unsigned generation,
    byte unsigned marker,
    int unsigned length = 64
  );
    rdma_hw_image image;

    image = new(name);
    for (int unsigned i = 0; i < length; i++)
      image.bytes.push_back(marker + byte'(i));
    image.length = length;
    image.alignment = (length == 0) ? 1 : length;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = image_kind;
    image.hardware_version = RDMA_HW_VERSION;
    image.function_generation = generation;
    image.write_target_kind = target_kind;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;
    case (target_kind)
      RDMA_HW_TARGET_BACKING:
        image.backing_target.value = 64'h0000_0001_0000_0000 + marker;
      RDMA_HW_TARGET_HMC_FVM:
        image.hmc_target.value = 64'h0000_0002_0000_0000 + marker;
      RDMA_HW_TARGET_BAR:
        image.bar_target.value = 64'h0000_0000_0000_0080;
      default: begin end
    endcase
    image.field_summary.push_back($sformatf("marker=%02h", marker));
    return image;
  endfunction

  // 功能：构造与 Function/CMQ/opcode/slot 完整绑定的 ticket 值。
  // 输入/输出及副作用：identity/cmq/sequence/command_id 为输入；返回 owned ticket graph。
  // 失败/边界：identity 或 cmq handle 缺失时返回的 graph 会被 validate 拒绝，不猜测默认权威。
  function automatic rdma_cmq_ticket make_journal_ticket(
    string name,
    rdma_function_identity identity,
    rdma_handle cmq_h,
    longint unsigned slot_sequence,
    longint unsigned command_id
  );
    rdma_cmq_ticket ticket;

    ticket = new(name);
    ticket.command_id = command_id;
    ticket.function_h = make_journal_function_handle(
      {name, "_function"}, identity
    );
    ticket.cmq_h = make_journal_handle(
      {name, "_cmq"}, RDMA_RESOURCE_CMQ, identity,
      (cmq_h == null) ? 0 : cmq_h.object_id
    );
    ticket.slot_sequence = slot_sequence;
    ticket.sq_index = slot_sequence % 32;
    ticket.sq_wrap = (slot_sequence / 32) % 2;
    ticket.opcode_key = new({name, "_opcode"});
    ticket.opcode_key.profile_name = "rdma";
    ticket.opcode_key.opcode = RDMA_OP_CQC_DELETE;
    ticket.opcode_key.variant = "CQC_DELETE";
    ticket.absolute_deadline = 10us + time'(command_id);
    return ticket;
  endfunction

  // 功能：从 prepared mapping 与 identity 构造完整 DMA request-context projection。
  // 输入/输出及副作用：mapping/cmq_h 只读；返回 detached context/handles。
  // 失败/边界：mapping 或 identity 缺失时返回 null；不复制 adapter 私有 allocation token。
  function automatic rdma_dma_request_context make_journal_dma_context(
    string name,
    rdma_function_identity identity,
    rdma_dma_mapping mapping,
    rdma_handle cmq_h
  );
    rdma_dma_request_context context;

    if (identity == null || mapping == null)
      return null;
    context = new(name);
    context.function_h = make_journal_function_handle(
      {name, "_function"}, identity
    );
    context.requester_bdf = mapping.requester_bdf;
    context.pasid_valid = mapping.pasid_valid;
    context.pasid = mapping.pasid;
    context.dma_domain_valid = mapping.dma_domain_valid;
    context.dma_domain_id = mapping.dma_domain_id;
    context.route = identity.route_key();
    context.reset_epoch = identity.reset_epoch;
    context.route_valid = 1'b1;
    context.epoch_valid = 1'b1;
    context.owner_h = make_journal_handle(
      {name, "_owner"}, RDMA_RESOURCE_CMQ, identity,
      (cmq_h == null) ? 0 : cmq_h.object_id
    );
    context.queue_role_valid = 1'b1;
    context.queue_role = 32'h434d_5101;
    return context;
  endfunction

  // 功能：按 journal ticket 的稳定不可变字段生成索引 key 期望值。
  // 输入/输出及副作用：ticket 为只读输入；返回 literal-format string，无副作用。
  // 失败/边界：ticket/Function 为空时返回空串，不尝试当前 runtime authority 校验。
  function automatic string journal_ticket_key(rdma_cmq_ticket ticket);
    if (ticket == null || ticket.function_h == null)
      return "";
    return $sformatf(
      "%016h:%08h:%08h:%016h",
      ticket.function_h.function_uid,
      ticket.function_h.object_id,
      ticket.function_h.generation,
      ticket.command_id
    );
  endfunction

  // 功能：为 journal fixture 直接构造 production profile 支持的指定 command-body graph。
  // 输入/输出及副作用：kind/name/identity/item_index 为输入；返回 QPC、object-ID、
  //   MR-deregister、OCC-flush 或 empty 的新 owned 值及其必要 nested handle。
  // 失败/边界：identity=null 或未知 kind 返回 null；所有合法分支都满足各 body validate()，
  //   且不经过 UVM factory，因而可在 hostile override 安装前安全准备 source graph。
  function automatic rdma_hw_model make_journal_command_body(
    rdma_cmq_test_journal_body_e kind,
    string name,
    rdma_function_identity identity,
    int unsigned item_index
  );
    rdma_hw_qpc_command_body qpc_body;
    rdma_hw_object_id_command_body object_body;
    rdma_hw_mr_deregister_body mr_body;
    rdma_hw_occ_flush_body occ_body;
    rdma_hw_cmq_empty_body empty_body;

    if (identity == null)
      return null;
    case (kind)
      RDMA_CMQ_TEST_JOURNAL_BODY_QPC: begin
        qpc_body = new(name);
        qpc_body.qp_h = make_journal_handle(
          {name, "_qp"}, RDMA_RESOURCE_QP, identity,
          32'h0000_0200 + item_index
        );
        qpc_body.qpc_buffer.value = 64'h0000_0001_1000_0000 +
                                   longint'(item_index) * 64'h1000;
        qpc_body.next_state = RDMA_QPS_RTS;
        return qpc_body;
      end
      RDMA_CMQ_TEST_JOURNAL_BODY_OBJECT_ID: begin
        object_body = new(name);
        object_body.object_h = make_journal_handle(
          {name, "_object"}, RDMA_RESOURCE_CQ, identity,
          32'h0000_0100 + item_index
        );
        return object_body;
      end
      RDMA_CMQ_TEST_JOURNAL_BODY_MR_DEREGISTER: begin
        mr_body = new(name);
        mr_body.mr_h = make_journal_handle(
          {name, "_mr"}, RDMA_RESOURCE_MR, identity,
          32'h0000_0300 + item_index
        );
        mr_body.stag_key = 8'h5a + byte'(item_index);
        mr_body.next_state = RDMA_CONTEXT_INVALID;
        return mr_body;
      end
      RDMA_CMQ_TEST_JOURNAL_BODY_OCC_FLUSH: begin
        occ_body = new(name);
        occ_body.eirqe = 1'b1;
        occ_body.orqe = 1'b1;
        occ_body.uaqe = 1'b1;
        occ_body.qpn = item_index;
        return occ_body;
      end
      RDMA_CMQ_TEST_JOURNAL_BODY_EMPTY: begin
        empty_body = new(name);
        return empty_body;
      end
      default: return null;
    endcase
  endfunction

  // 功能：构造两项完整 journal record 与一一对应的 preallocated publication value；
  //   source record 使用与 engine backing 分离但保留 opaque release authority 的 mapping。
  // 输入/输出及副作用：engine/profile/binding/cmq、稳定 ID 与 body_kind 为输入；成功
  //   直接复制 mapping 全部公开字段，经 profile 计算 digest 并发布两个 source graph。
  // 失败/边界：任一依赖、未知 body kind、mapping authority seam、nested handle、
  //   identity/profile canonicalization 或 digest 失败时输出均为 null，不安装 DUT 行。
  function automatic rdma_status build_journal_fixture(
    string name,
    rdma_cmq_engine_probe engine,
    rdma_cmq_hw_profile profile_service,
    rdma_function_binding binding,
    rdma_cmq cmq,
    string batch_key,
    longint unsigned batch_id,
    longint unsigned attempt_id,
    longint unsigned first_command_id,
    rdma_cmq_test_journal_body_e body_kind,
    output rdma_cmq_batch_submission_record record,
    output rdma_cmq_preallocated_publish_batch preallocated
  );
    rdma_function_identity identity;
    rdma_dma_mapping live_mapping;
    rdma_dma_mapping mapping;
    rdma_handle function_snapshot_base;
    rdma_handle owner_snapshot;
    rdma_cmq_recovery_owner shared_owner;
    rdma_status status;
    int unsigned request_indices[$];
    rdma_cmq_journal_digest_t image_digests[$];
    rdma_cmq_journal_digest_t authority_digests[$];

    record = null;
    preallocated = null;
    if (engine == null || profile_service == null || binding == null ||
        cmq == null || cmq.handle == null || batch_key.len() == 0 ||
        batch_id == 0 || attempt_id == 0 || first_command_id == 0)
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_ARGUMENT,
        "journal fixture fixed input is incomplete"
      );

    status = binding.snapshot_identity_nonfatal(identity);
    if (status == null || !status.ok() || identity == null)
      return (status == null) ? rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "journal fixture identity snapshot returned null status"
      ) : status;
    live_mapping = engine.journal_mapping_reference();
    if (live_mapping == null)
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "journal fixture prepared mapping is missing"
      );
    status = live_mapping.snapshot_release_authority(mapping);
    if (status == null)
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "journal fixture mapping authority snapshot returned null status"
      );
    if (!status.ok())
      return status;
    if (mapping == null || mapping == live_mapping ||
        mapping.get_object_type() != live_mapping.get_object_type())
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_ARGUMENT,
        "journal fixture mapping authority snapshot is null, aliased or sliced"
      );
    if (!rdma_cmq_try_snapshot_handle_direct(
          live_mapping.function_h, 1'b0, function_snapshot_base
        ) || !rdma_cmq_try_snapshot_handle_direct(
          live_mapping.owner_h, 1'b1, owner_snapshot
        ) || !$cast(mapping.function_h, function_snapshot_base))
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_ARGUMENT,
        "journal fixture mapping nested handle snapshot failed"
      );
    mapping.requester_bdf = live_mapping.requester_bdf;
    mapping.pasid_valid = live_mapping.pasid_valid;
    mapping.pasid = live_mapping.pasid;
    mapping.dma_domain_valid = live_mapping.dma_domain_valid;
    mapping.dma_domain_id = live_mapping.dma_domain_id;
    mapping.route = live_mapping.route;
    mapping.reset_epoch = live_mapping.reset_epoch;
    mapping.route_valid = live_mapping.route_valid;
    mapping.epoch_valid = live_mapping.epoch_valid;
    mapping.backing_addr = live_mapping.backing_addr;
    mapping.iova = live_mapping.iova;
    mapping.size = live_mapping.size;
    mapping.direction = live_mapping.direction;
    mapping.permissions = live_mapping.permissions;
    mapping.state = live_mapping.state;
    mapping.owner_h = owner_snapshot;
    mapping.umem_ref = live_mapping.umem_ref;
    mapping.pbl_ref = live_mapping.pbl_ref;
    mapping.mw_ref = live_mapping.mw_ref;
    mapping.umem_backed = live_mapping.umem_backed;
    mapping.umem_page_count = live_mapping.umem_page_count;
    status = live_mapping.release_authority_status(mapping);
    if (status == null)
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "journal fixture mapping authority verification returned null status"
      );
    if (!status.ok())
      return status;
    if (!same_mapping_fields(live_mapping, mapping) ||
        mapping.function_h == live_mapping.function_h ||
        (live_mapping.owner_h != null &&
         mapping.owner_h == live_mapping.owner_h))
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_ARGUMENT,
        "journal fixture mapping snapshot changed value or retained an alias"
      );

    shared_owner = new({name, "_owner"});
    shared_owner.workflow = RDMA_CMQ_WORKFLOW_QUEUE;
    shared_owner.resource_h = make_journal_handle(
      {name, "_owner_resource"}, RDMA_RESOURCE_CQ, identity, 32'h0000_0055
    );
    shared_owner.transaction_id = 64'h1122_3344_5566_7788;
    shared_owner.allowed_actions = 3'b110;
    status = shared_owner.freeze_for_journal(identity, attempt_id);
    if (status == null || !status.ok())
      return (status == null) ? rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "journal fixture owner freeze returned null status"
      ) : status;

    record = new({name, "_record"});
    record.batch_key = batch_key;
    record.batch_id = batch_id;
    record.attempt_id = attempt_id;
    record.engine_instance_id = engine.journal_engine_instance_id();
    record.engine_incarnation = engine.journal_engine_incarnation();
    record.function_identity = identity;
    record.binding = binding;
    record.cmq_h = make_journal_handle(
      {name, "_cmq"}, RDMA_RESOURCE_CMQ, identity, cmq.handle.object_id
    );
    record.start_sequence = 4;
    record.end_sequence = 6;
    record.doorbell_image = make_journal_image(
      {name, "_doorbell"}, RDMA_IMAGE_DOORBELL, RDMA_HW_TARGET_BAR,
      identity.generation, 8'hd0, 8
    );
    record.final_pi = 6;
    record.final_polarity = 1'b0;
    record.state = RDMA_CMQ_SUBMISSION_COMPLETED;
    record.submission_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    record.attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    record.observer_armed = 1'b1;
    record.publication_retry_safe = 1'b0;
    record.reset_isolation_proof = null;

    preallocated = new({name, "_preallocated"});
    preallocated.batch_key = batch_key;
    preallocated.attempt_id = attempt_id;
    preallocated.final_sequence = record.end_sequence;
    preallocated.profile_format_valid = 1'b1;
    preallocated.profile_endian = RDMA_ENDIAN_BIG;
    preallocated.profile_hardware_version = RDMA_HW_VERSION;

    for (int unsigned i = 0; i < 2; i++) begin
      rdma_cmq_batch_submission_item_record item;
      rdma_cmq_preallocated_publish_item publish_item;
      rdma_hw_cmq_completion payload;
      rdma_cmq_expected_response expected;
      string body_tag;
      byte unsigned body_bytes[];

      item = new($sformatf("%s_item_%0d", name, i));
      item.request_index = i;
      item.command = new($sformatf("%s_command_%0d", name, i));
      item.command.function_h = make_journal_function_handle(
        $sformatf("%s_command_function_%0d", name, i), identity
      );
      item.command.opcode_key = new(
        $sformatf("%s_command_opcode_%0d", name, i)
      );
      item.command.opcode_key.profile_name = "rdma";
      item.command.opcode_key.opcode = RDMA_OP_CQC_DELETE;
      item.command.opcode_key.variant = "CQC_DELETE";
      item.command.body = make_journal_command_body(
        body_kind, $sformatf("%s_body_%0d", name, i), identity, i
      );
      if (item.command.body == null) begin
        record = null;
        preallocated = null;
        return rdma_cmq_direct_status(
          RDMA_SC_INVALID_ARGUMENT,
          "journal fixture command body kind is unsupported"
        );
      end
      item.command.qpc_signature_source = null;
      item.command.vfid_override = 1'b0;
      item.command.use_vfid = 0;
      item.command.timeout = 1us + i * 1ns;
      item.command.recovery_owner = shared_owner;

      item.ticket = make_journal_ticket(
        $sformatf("%s_ticket_%0d", name, i), identity, record.cmq_h,
        record.start_sequence + i, first_command_id + i
      );
      item.recovery_owner = shared_owner;
      item.dma_context = make_journal_dma_context(
        $sformatf("%s_dma_%0d", name, i), identity, mapping, record.cmq_h
      );
      item.sqe_image = make_journal_image(
        $sformatf("%s_sqe_%0d", name, i), RDMA_IMAGE_CMQ_SQE,
        RDMA_HW_TARGET_BACKING, identity.generation, 8'h20 + byte'(i)
      );
      item.dependency_mapping = mapping;
      item.dependency_offset = 64 * i;
      item.dependency_image = make_journal_image(
        $sformatf("%s_dependency_%0d", name, i), RDMA_IMAGE_CMQ_SQE,
        RDMA_HW_TARGET_BACKING, identity.generation, 8'h40 + byte'(i)
      );
      item.slot_sequence = item.ticket.slot_sequence;
      item.slot_index = item.ticket.sq_index;
      item.slot_wrap = item.ticket.sq_wrap;
      item.command_token = i + 1'b1;
      item.token_incarnation = record.engine_incarnation[58:0];
      item.entry_key = $sformatf(
        "%016h:%08h:%0d:%0b", identity.function_uid,
        identity.generation, item.slot_index, item.slot_wrap
      );
      item.dependency_replay_safe = 1'b1;
      item.state = RDMA_CMQ_SUBMISSION_COMPLETED;
      item.submission_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
      item.attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
      item.completion_phase = RDMA_CMQ_COMPLETION_TERMINAL;
      item.reset_isolation_confirmed = 1'b0;
      item.recovery_required = 1'b0;
      item.status = rdma_cmq_direct_status(RDMA_SC_OK, "journal item OK");
      item.status.source_engine = RDMA_ENGINE_CMQ;
      item.status.function_uid = identity.function_uid;
      item.status.generation = identity.generation;
      item.status.resource_id = record.cmq_h.object_id;
      item.status.command_id = item.ticket.command_id;

      item.completion = new($sformatf("%s_completion_%0d", name, i));
      item.completion.ticket = item.ticket;
      item.completion.status = item.status;
      item.completion.raw_cqe = make_journal_image(
        $sformatf("%s_cqe_%0d", name, i), RDMA_IMAGE_CMQ_CQE,
        RDMA_HW_TARGET_NONE, identity.generation, 8'h80 + byte'(i)
      );
      payload = new($sformatf("%s_payload_%0d", name, i));
      payload.owner = i[0];
      payload.opcode = RDMA_OP_CQC_DELETE;
      payload.command_ecode = 0;
      payload.wqe_index = item.ticket.sq_index;
      payload.wrap = item.ticket.sq_wrap;
      payload.object_payload = new[3];
      foreach (payload.object_payload[j])
        payload.object_payload[j] = byte'(8'ha0 + 8 * i + j);
      item.completion.decoded_response = payload;

      status = profile_service.canonicalize_command_body(
        item.command.body, body_tag, body_bytes
      );
      if (status == null || !status.ok()) begin
        record = null;
        preallocated = null;
        return (status == null) ? rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "journal fixture profile canonicalization returned null status"
        ) : status;
      end
      status = rdma_cmq_compute_item_digests(
        item.command, body_tag, body_bytes, item.ticket,
        item.recovery_owner, identity, item.dma_context, item.sqe_image,
        item.dependency_mapping, item.dependency_offset,
        item.dependency_image, item.image_digest, item.authority_digest
      );
      if (status == null || !status.ok()) begin
        record = null;
        preallocated = null;
        return (status == null) ? rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE,
          "journal fixture item digest returned null status"
        ) : status;
      end
      record.items.push_back(item);
      request_indices.push_back(item.request_index);
      image_digests.push_back(item.image_digest);
      authority_digests.push_back(item.authority_digest);

      publish_item = new($sformatf("%s_publish_item_%0d", name, i));
      publish_item.request_index = item.request_index;
      publish_item.slot_record = new(
        $sformatf("%s_slot_record_%0d", name, i)
      );
      publish_item.slot_record.slot_sequence = item.slot_sequence;
      publish_item.slot_record.sq_index = item.slot_index;
      publish_item.slot_record.sq_wrap = item.slot_wrap;
      publish_item.slot_record.state = CMQ_SLOT_PUBLISHED;
      publish_item.slot_record.ticket = item.ticket;
      expected = new($sformatf("%s_expected_%0d", name, i));
      expected.hardware_opcode = RDMA_OP_CQC_DELETE;
      expected.variant = "CQC_DELETE";
      publish_item.slot_record.expected = expected;
      publish_item.slot_record.command_token = item.command_token;
      publish_item.command_key = journal_ticket_key(item.ticket);
      publish_item.entry_key = item.entry_key;
      publish_item.command_token = item.command_token;
      preallocated.items.push_back(publish_item);
    end

    status = rdma_cmq_compute_batch_digest(
      record.function_identity, record.binding, record.cmq_h,
      record.doorbell_image, record.final_pi, record.final_polarity,
      record.start_sequence, record.end_sequence, request_indices,
      image_digests, authority_digests, record.batch_digest
    );
    if (status == null || !status.ok()) begin
      record = null;
      preallocated = null;
      return (status == null) ? rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "journal fixture batch digest returned null status"
      ) : status;
    end
    return rdma_cmq_direct_status(RDMA_SC_OK);
  endfunction

  // 功能：把完整 journal fixture 改成 doorbell 已 HOST_MEMORY_ORDERED、
  //   但尚未进入 MMIO 的 PENDING_EFFECT arm 前状态。
  // 输入/输出及副作用：record 为 inout；改写 batch/item lifecycle，清除
  //   completion 并保留 digest authority、ticket 与预分配图。
  // 失败/边界：record 为 null 或含 null item 时返回 0 且不保证 partial 改写回滚；
  //   调用方只能对新建、尚未安装的 fixture 使用。
  function automatic bit make_pending_mmio_arm_fixture(
    inout rdma_cmq_batch_submission_record record
  );
    if (record == null)
      return 1'b0;
    foreach (record.items[i]) begin
      if (record.items[i] == null)
        return 1'b0;
    end

    record.state = RDMA_CMQ_SUBMISSION_PENDING_EFFECT;
    record.submission_effect = RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED;
    record.attempt_effect = RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED;
    record.observer_armed = 1'b0;
    foreach (record.items[i]) begin
      record.items[i].state = RDMA_CMQ_SUBMISSION_PENDING_EFFECT;
      record.items[i].submission_effect =
        RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED;
      record.items[i].attempt_effect = RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED;
      record.items[i].completion_phase = RDMA_CMQ_COMPLETION_NONE;
      record.items[i].reset_isolation_confirmed = 1'b0;
      record.items[i].recovery_required = 1'b1;
      record.items[i].completion = null;
    end
    return 1'b1;
  endfunction

  // 功能：调用一次应被拒绝的 observer，断言诊断递增且 arm 账本逐值不变。
  // 输入/输出及副作用：label 用于诊断，batch_key 定位真实 authority record；
  //   engine/observer/catcher 为非拥有输入，回调前后比较该 record 的 fingerprint。
  // 失败/边界：三个句柄任一为 null 或 batch_key 为空时直接报 fixture error；本 helper
  //   不吞掉非目标 UVM report，也不修复被 DUT 错误改写的状态。
  function automatic void expect_mmio_arm_invalid_unchanged(
    string label,
    string batch_key,
    rdma_cmq_engine_probe engine,
    rdma_cmq_mmio_arm_observer observer,
    rdma_cmq_mmio_arm_error_catcher catcher
  );
    string before_state;
    string after_state;
    int unsigned before_errors;

    if (batch_key.len() == 0 || engine == null || observer == null ||
        catcher == null) begin
      `uvm_error({label, "_FIXTURE"},
                 "MMIO arm rejection fixture handle or batch key is invalid")
      return;
    end
    before_state = engine.mmio_arm_state_fingerprint(batch_key);
    before_errors = catcher.caught_count;
    observer.before_mmio_maybe_visible();
    after_state = engine.mmio_arm_state_fingerprint(batch_key);
    if (catcher.caught_count != before_errors + 1)
      `uvm_error({label, "_DIAGNOSTIC"},
                 "invalid MMIO arm did not emit exactly one stable error")
    if (after_state != before_state)
      `uvm_error({label, "_ATOMICITY"},
                 "invalid MMIO arm changed journal, cursor or registry state")
  endfunction

  // 功能：从完整两项 journal record 构造 execution-result、recovery request
  //   与 reset-proof source graph，供 nonfatal snapshot seam 联合覆盖。
  // 输入/输出及副作用：record 为只读输入；成功发布三个本地 owned outer 值，
  //   嵌套 ticket/status/owner 故意保留 source alias 以验证 context canonicalization。
  // 失败/边界：record/两项 graph/digest 前置不完整或 proof digest 失败时全部输出 null。
  function automatic rdma_status build_journal_recovery_graphs(
    string name,
    rdma_cmq_batch_submission_record record,
    output rdma_cmq_execution_result result,
    output rdma_cmq_submission_recovery_request request,
    output rdma_cmq_reset_isolation_proof proof
  );
    int unsigned request_indices[$];
    rdma_cmq_journal_digest_t image_digests[$];
    rdma_cmq_journal_digest_t authority_digests[$];
    rdma_cmq_recovery_owner owners[$];
    rdma_status status;
    string failure_reason;

    result = null;
    request = null;
    proof = null;
    if (record == null || record.items.size() != 2 ||
        record.function_identity == null || record.binding == null ||
        record.cmq_h == null || record.doorbell_image == null)
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_ARGUMENT,
        "recovery graph source record is incomplete"
      );
    foreach (record.items[i]) begin
      if (record.items[i] == null || record.items[i].command == null ||
          record.items[i].ticket == null ||
          record.items[i].recovery_owner == null ||
          record.items[i].dma_context == null ||
          record.items[i].sqe_image == null ||
          record.items[i].dependency_mapping == null ||
          record.items[i].dependency_image == null) begin
        result = null;
        request = null;
        proof = null;
        return rdma_cmq_direct_status(
          RDMA_SC_INVALID_ARGUMENT,
          "recovery graph journal item is incomplete"
        );
      end
      request_indices.push_back(record.items[i].request_index);
      image_digests.push_back(record.items[i].image_digest);
      authority_digests.push_back(record.items[i].authority_digest);
      owners.push_back(record.items[i].recovery_owner);
    end

    proof = new({name, "_proof"});
    proof.proof_key = {record.batch_key, "|proof=0000000000000001"};
    proof.proof_id = 1;
    proof.batch_key = record.batch_key;
    proof.batch_id = record.batch_id;
    proof.attempt_id = record.attempt_id;
    proof.engine_instance_id = record.engine_instance_id;
    proof.engine_incarnation = record.engine_incarnation;
    proof.isolated_identity = record.function_identity;
    proof.replacement_identity = null;
    proof.batch_digest = record.batch_digest;
    proof.isolated_request_indices = request_indices;
    proof.isolated_image_digests = image_digests;
    proof.isolated_authority_digests = authority_digests;
    proof.isolated_recovery_owners = owners;
    proof.state = RDMA_CMQ_RESET_PROOF_AWAITING_REBIND;
    proof.backing_release_confirmed = 1'b1;
    status = rdma_cmq_compute_reset_proof_digest(
      proof.proof_key, proof.proof_id, proof.batch_key, proof.batch_id,
      proof.attempt_id, proof.engine_instance_id, proof.engine_incarnation,
      proof.isolated_identity, proof.batch_digest, request_indices,
      image_digests, authority_digests, owners, proof.proof_digest
    );
    if (status == null || !status.ok()) begin
      result = null;
      request = null;
      proof = null;
      return (status == null) ? rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE,
        "recovery graph proof digest returned null status"
      ) : status;
    end

    result = new({name, "_result"});
    result.ticket = record.items[0].ticket;
    result.completion = record.items[0].completion;
    result.status = record.items[0].status;
    result.observation_status = rdma_cmq_direct_status(
      RDMA_SC_OK, "journal observation OK"
    );
    result.command_identity = new({name, "_command_identity"});
    if (!result.command_identity.capture_from(
          record.items[0].command, failure_reason
        )) begin
      result = null;
      request = null;
      proof = null;
      return rdma_cmq_direct_status(
        RDMA_SC_INVALID_ARGUMENT,
        {"recovery graph command identity failed: ", failure_reason}
      );
    end
    result.recovery_owner = record.items[0].recovery_owner;
    result.dma_context = record.items[0].dma_context;
    result.submission_effect = record.items[0].submission_effect;
    result.attempt_effect = record.items[0].attempt_effect;
    result.completion_phase = record.items[0].completion_phase;
    result.batch_key = record.batch_key;
    result.batch_id = record.batch_id;
    result.attempt_id = record.attempt_id;
    result.recovery_required = record.items[0].recovery_required;

    request = new({name, "_request"});
    request.batch_key = record.batch_key;
    request.batch_id = record.batch_id;
    request.expected_attempt_id = record.attempt_id;
    request.expected_function_identity = record.function_identity;
    request.binding = record.binding;
    request.cmq_h = record.cmq_h;
    request.start_sequence = record.start_sequence;
    request.end_sequence = record.end_sequence;
    request.doorbell_image = record.doorbell_image;
    request.final_pi = record.final_pi;
    request.final_polarity = record.final_polarity;
    request.batch_digest = record.batch_digest;
    request.action = RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION;
    request.reset_isolation_proof = proof;
    foreach (record.items[i]) begin
      rdma_cmq_submission_recovery_item recovery_item;

      recovery_item = new($sformatf("%s_recovery_item_%0d", name, i));
      recovery_item.request_index = record.items[i].request_index;
      recovery_item.command = record.items[i].command;
      recovery_item.ticket = record.items[i].ticket;
      recovery_item.recovery_owner = record.items[i].recovery_owner;
      recovery_item.dma_context = record.items[i].dma_context;
      recovery_item.sqe_image = record.items[i].sqe_image;
      recovery_item.dependency_mapping =
        record.items[i].dependency_mapping;
      recovery_item.dependency_offset = record.items[i].dependency_offset;
      recovery_item.dependency_image = record.items[i].dependency_image;
      recovery_item.image_digest = record.items[i].image_digest;
      recovery_item.authority_digest = record.items[i].authority_digest;
      request.items.push_back(recovery_item);
    end
    return rdma_cmq_direct_status(RDMA_SC_OK);
  endfunction

  // 功能：断言 journal query 返回完整、值相等且跨图分离的两项 snapshot。
  // 输入/输出及副作用：engine/profile/snapshot/source 为只读输入；仅发布 UVM_ERROR。
  // 失败/边界：任何 required node、alias topology、opaque mapping authority 或值字段
  //   不一致均报错并避免继续解引用缺失节点。
  function automatic void expect_journal_snapshot(
    string label,
    rdma_cmq_engine_probe engine,
    rdma_cmq_hw_profile profile_service,
    rdma_cmq_batch_submission_record snapshot,
    rdma_cmq_batch_submission_record source
  );
    if (engine == null || profile_service == null || snapshot == null ||
        source == null) begin
      `uvm_error(label, "journal snapshot prerequisites are null")
      return;
    end
    if (snapshot == source || snapshot.batch_key != source.batch_key ||
        snapshot.batch_id != source.batch_id ||
        snapshot.attempt_id != source.attempt_id ||
        snapshot.engine_instance_id != source.engine_instance_id ||
        snapshot.engine_incarnation != source.engine_incarnation ||
        snapshot.start_sequence != source.start_sequence ||
        snapshot.end_sequence != source.end_sequence ||
        snapshot.final_pi != source.final_pi ||
        snapshot.final_polarity != source.final_polarity ||
        snapshot.batch_digest != source.batch_digest ||
        snapshot.state != source.state ||
        snapshot.submission_effect != source.submission_effect ||
        snapshot.attempt_effect != source.attempt_effect ||
        snapshot.observer_armed != source.observer_armed ||
        snapshot.publication_retry_safe != source.publication_retry_safe ||
        snapshot.reset_isolation_proof != null ||
        snapshot.items.size() != source.items.size()) begin
      `uvm_error(label, "journal snapshot outer value differs from source")
      return;
    end
    if (snapshot.function_identity == null ||
        snapshot.function_identity == source.function_identity ||
        !snapshot.function_identity.same_incarnation(
          source.function_identity
        ) || snapshot.binding == null ||
        snapshot.binding == source.binding || snapshot.cmq_h == null ||
        snapshot.cmq_h == source.cmq_h ||
        !snapshot.cmq_h.same_instance(source.cmq_h) ||
        snapshot.doorbell_image == null ||
        snapshot.doorbell_image == source.doorbell_image ||
        !engine.probe_same_image(
          snapshot.doorbell_image, source.doorbell_image
        ))
      `uvm_error(label, "journal batch authority is aliased or unequal")

    foreach (source.items[i]) begin
      rdma_hw_object_id_command_body source_body;
      rdma_hw_object_id_command_body snapshot_body;
      rdma_hw_cmq_completion source_payload;
      rdma_hw_cmq_completion snapshot_payload;
      rdma_mock_dma_mapping source_mapping;
      rdma_mock_dma_mapping snapshot_mapping;
      rdma_cmq_batch_submission_item_record lhs;
      rdma_cmq_batch_submission_item_record rhs;

      lhs = source.items[i];
      rhs = snapshot.items[i];
      if (lhs == null || rhs == null || rhs == lhs || rhs.command == null ||
          rhs.ticket == null || rhs.recovery_owner == null ||
          rhs.dma_context == null || rhs.sqe_image == null ||
          rhs.dependency_mapping == null || rhs.dependency_image == null ||
          rhs.completion == null || rhs.status == null) begin
        `uvm_error(label, $sformatf("journal item %0d is incomplete", i))
        continue;
      end
      if (rhs.request_index != lhs.request_index ||
          rhs.dependency_offset != lhs.dependency_offset ||
          rhs.slot_sequence != lhs.slot_sequence ||
          rhs.slot_index != lhs.slot_index || rhs.slot_wrap != lhs.slot_wrap ||
          rhs.command_token != lhs.command_token ||
          rhs.token_incarnation != lhs.token_incarnation ||
          rhs.entry_key != lhs.entry_key ||
          rhs.image_digest != lhs.image_digest ||
          rhs.authority_digest != lhs.authority_digest ||
          rhs.dependency_replay_safe != lhs.dependency_replay_safe ||
          rhs.state != lhs.state ||
          rhs.submission_effect != lhs.submission_effect ||
          rhs.attempt_effect != lhs.attempt_effect ||
          rhs.completion_phase != lhs.completion_phase ||
          rhs.reset_isolation_confirmed != lhs.reset_isolation_confirmed ||
          rhs.recovery_required != lhs.recovery_required)
        `uvm_error(label, $sformatf("journal item %0d scalar drift", i))
      if (rhs.command == lhs.command || rhs.command.body == lhs.command.body ||
          !profile_service.same_command_body_value(
            lhs.command.body, rhs.command.body
          ) || !profile_service.command_body_graph_detached(
            lhs.command.body, rhs.command.body
          ) || rhs.command.recovery_owner != rhs.recovery_owner ||
          rhs.recovery_owner == lhs.recovery_owner)
        `uvm_error(label,
                   $sformatf("journal item %0d command/owner alias drift", i))
      if ($cast(source_body, lhs.command.body) &&
          (!$cast(snapshot_body, rhs.command.body) ||
           snapshot_body.object_h == null || source_body.object_h == null ||
           snapshot_body.object_h == source_body.object_h))
        `uvm_error(label, $sformatf(
          "journal item %0d object-ID body is not detached", i
        ))
      if (rhs.ticket == lhs.ticket || rhs.completion == lhs.completion ||
          rhs.completion.ticket != rhs.ticket ||
          rhs.completion.status != rhs.status || rhs.status == lhs.status)
        `uvm_error(label,
                   $sformatf("journal item %0d ticket/status alias drift", i))
      if (rhs.ticket.command_id != lhs.ticket.command_id ||
          rhs.ticket.slot_sequence != lhs.ticket.slot_sequence ||
          rhs.ticket.absolute_deadline != lhs.ticket.absolute_deadline)
        `uvm_error(label,
                   $sformatf("journal item %0d ticket value drift", i))
      if (rhs.dma_context == lhs.dma_context ||
          rhs.dma_context.function_h == lhs.dma_context.function_h ||
          rhs.dma_context.owner_h == lhs.dma_context.owner_h ||
          rhs.sqe_image == lhs.sqe_image ||
          !engine.probe_same_image(rhs.sqe_image, lhs.sqe_image) ||
          rhs.dependency_image == lhs.dependency_image ||
          !engine.probe_same_image(
            rhs.dependency_image, lhs.dependency_image
          ))
        `uvm_error(label,
                   $sformatf("journal item %0d DMA/image graph is aliased", i))
      if (!$cast(source_mapping, lhs.dependency_mapping) ||
          !$cast(snapshot_mapping, rhs.dependency_mapping) ||
          snapshot_mapping == source_mapping ||
          !same_mapping_fields(snapshot_mapping, source_mapping) ||
          !source_mapping.same_allocation(snapshot_mapping))
        `uvm_error(label,
                   $sformatf("journal item %0d mapping authority changed", i))
      if (rhs.completion.raw_cqe == null ||
          rhs.completion.raw_cqe == lhs.completion.raw_cqe ||
          !engine.probe_same_image(
            rhs.completion.raw_cqe, lhs.completion.raw_cqe
          ) || !$cast(source_payload, lhs.completion.decoded_response) ||
          !$cast(snapshot_payload, rhs.completion.decoded_response) ||
          snapshot_payload == source_payload ||
          !profile_service.same_completion_payload_value(
            source_payload, snapshot_payload
          ) || !profile_service.completion_payload_graph_detached(
            source_payload, snapshot_payload
          ))
        `uvm_error(label,
                   $sformatf("journal item %0d completion graph drift", i))
    end
  endfunction

  // 功能：逐层篡改 query snapshot 的所有 owned nested categories，验证二次查询隔离。
  // 输入/输出及副作用：snapshot 为 inout；修改 outer/identity/binding/handles/images/
  //   command/body/owner/ticket/DMA/mapping/completion/status/payload 的代表字段。
  // 失败/边界：graph 缺失时跳过对应层并由后续 expect_journal_snapshot 报错；不触碰 source/DUT。
  function automatic void mutate_journal_snapshot(
    rdma_cmq_batch_submission_record snapshot
  );
    if (snapshot == null)
      return;
    snapshot.batch_id++;
    snapshot.batch_key = {snapshot.batch_key, "|mutated"};
    snapshot.batch_digest[0] = !snapshot.batch_digest[0];
    if (snapshot.function_identity != null)
      snapshot.function_identity.reset_epoch++;
    if (snapshot.binding != null)
      snapshot.binding.vsi_id++;
    if (snapshot.cmq_h != null)
      snapshot.cmq_h.object_id++;
    if (snapshot.doorbell_image != null &&
        snapshot.doorbell_image.bytes.size() != 0)
      snapshot.doorbell_image.bytes[0]++;
    foreach (snapshot.items[i]) begin
      rdma_hw_object_id_command_body body;
      rdma_hw_cmq_completion payload;

      if (snapshot.items[i] == null)
        continue;
      snapshot.items[i].request_index++;
      snapshot.items[i].entry_key = "mutated-entry";
      if (snapshot.items[i].command != null) begin
        snapshot.items[i].command.timeout++;
        if (snapshot.items[i].command.function_h != null)
          snapshot.items[i].command.function_h.object_id++;
        if (snapshot.items[i].command.opcode_key != null)
          snapshot.items[i].command.opcode_key.variant = "mutated-variant";
        if ($cast(body, snapshot.items[i].command.body) &&
            body.object_h != null)
          body.object_h.object_id++;
      end
      if (snapshot.items[i].recovery_owner != null) begin
        snapshot.items[i].recovery_owner.transaction_id++;
        if (snapshot.items[i].recovery_owner.resource_h != null)
          snapshot.items[i].recovery_owner.resource_h.object_id++;
        if (snapshot.items[i].recovery_owner.function_identity != null)
          snapshot.items[i].recovery_owner.function_identity.reset_epoch++;
      end
      if (snapshot.items[i].ticket != null) begin
        snapshot.items[i].ticket.command_id++;
        if (snapshot.items[i].ticket.function_h != null)
          snapshot.items[i].ticket.function_h.object_id++;
        if (snapshot.items[i].ticket.cmq_h != null)
          snapshot.items[i].ticket.cmq_h.object_id++;
      end
      if (snapshot.items[i].dma_context != null) begin
        snapshot.items[i].dma_context.dma_domain_id++;
        if (snapshot.items[i].dma_context.function_h != null)
          snapshot.items[i].dma_context.function_h.object_id++;
        if (snapshot.items[i].dma_context.owner_h != null)
          snapshot.items[i].dma_context.owner_h.object_id++;
      end
      if (snapshot.items[i].sqe_image != null &&
          snapshot.items[i].sqe_image.bytes.size() != 0)
        snapshot.items[i].sqe_image.bytes[0]++;
      if (snapshot.items[i].dependency_mapping != null) begin
        snapshot.items[i].dependency_mapping.size++;
        if (snapshot.items[i].dependency_mapping.function_h != null)
          snapshot.items[i].dependency_mapping.function_h.object_id++;
        if (snapshot.items[i].dependency_mapping.owner_h != null)
          snapshot.items[i].dependency_mapping.owner_h.object_id++;
      end
      if (snapshot.items[i].dependency_image != null &&
          snapshot.items[i].dependency_image.bytes.size() != 0)
        snapshot.items[i].dependency_image.bytes[0]++;
      if (snapshot.items[i].status != null)
        snapshot.items[i].status.message = "mutated-status";
      if (snapshot.items[i].completion != null) begin
        if (snapshot.items[i].completion.raw_cqe != null &&
            snapshot.items[i].completion.raw_cqe.bytes.size() != 0)
          snapshot.items[i].completion.raw_cqe.bytes[0]++;
        if ($cast(payload,
                  snapshot.items[i].completion.decoded_response) &&
            payload.object_payload.size() != 0)
          payload.object_payload[0]++;
      end
    end
  endfunction

  // 功能：断言一个 malformed initial journal candidate 被 INVALID_ARGUMENT 原子拒绝。
  // 输入/输出及副作用：label/engine/record/preallocated 为输入；调用真实安装入口，
  //   若旧实现错误安装则立即经真实 remove helper 清理，以隔离后续 RED assertion。
  // 失败/边界：status 非 INVALID_ARGUMENT、清理失败或四张表留下任一行时发布 UVM_ERROR；
  //   调用方必须在空 journal engine 上逐项恢复 candidate 后再调用下一次。
  function automatic void expect_candidate_journal_rejection(
    string label,
    rdma_cmq_engine_probe engine,
    rdma_cmq_batch_submission_record record,
    rdma_cmq_preallocated_publish_batch preallocated
  );
    rdma_status status;
    rdma_status cleanup_status;

    status = engine.install_submission_journal_probe(record, preallocated);
    expect_status(label, status, RDMA_SC_INVALID_ARGUMENT);
    if (status != null && status.ok()) begin
      cleanup_status = engine.remove_submission_journal_probe(record.batch_key);
      expect_status({label, "_RED_CLEANUP"}, cleanup_status, RDMA_SC_OK);
    end
    if (engine.submission_journal_count() != 0 ||
        engine.journal_ticket_index_count() != 0 ||
        engine.preallocated_publish_batch_count() != 0 ||
        engine.journal_profile_count() != 0)
      `uvm_error({label, "_ATOMIC"},
                 "malformed candidate left one or more journal rows")
  endfunction

  // 功能：通过 batch 与 ticket 两个 public API 断言 stored corruption 统一 fail-closed。
  // 输入/输出及副作用：label/engine/batch_key/caller_ticket 为输入；两次查询都要求
  //   INVALID_STATE 且 output 为 null，不修改 retained row 或 caller ticket。
  // 失败/边界：任一 API 返回其他 code、null status 或 partial record 时发布 UVM_ERROR；
  //   ticket 必须是腐化前保存的合法 detached caller value。
  task automatic expect_stored_journal_rejection(
    string label,
    rdma_cmq_engine_probe engine,
    string batch_key,
    rdma_cmq_ticket caller_ticket
  );
    rdma_cmq_batch_submission_record snapshot;
    rdma_status status;

    engine.query_submission_journal(batch_key, snapshot, status);
    expect_status({label, "_BATCH"}, status, RDMA_SC_INVALID_STATE);
    if (snapshot != null)
      `uvm_error({label, "_BATCH_OUTPUT"},
                 "stored corruption published a batch snapshot")
    engine.query_submission_journal_by_ticket(
      caller_ticket, snapshot, status
    );
    expect_status({label, "_TICKET"}, status, RDMA_SC_INVALID_STATE);
    if (snapshot != null)
      `uvm_error({label, "_TICKET_OUTPUT"},
                 "stored corruption published a ticket snapshot")
  endtask

  // 功能：安装 Task 13 全部 outer/body/payload hostile raw-factory override。
  // 输入/输出及副作用：无输入；永久更新本次 UVM test 的 global factory override 表。
  // 失败/边界：UVM override 无撤销契约，因此本 helper 只能在 run_phase 最后场景调用。
  function automatic void configure_journal_factory_traps();
    uvm_factory factory;

    factory = uvm_factory::get();
    factory.set_type_override_by_type(
      rdma_cmq_command_desc::get_type(),
      rdma_cmq_factory_trap_command::get_type()
    );
    factory.set_type_override_by_type(
      rdma_cmq_completion::get_type(),
      rdma_cmq_factory_trap_completion::get_type()
    );
    factory.set_type_override_by_type(
      rdma_cmq_execution_result::get_type(),
      rdma_cmq_factory_trap_result::get_type()
    );
    factory.set_type_override_by_type(
      rdma_cmq_batch_submission_record::get_type(),
      rdma_cmq_factory_trap_record::get_type()
    );
    factory.set_type_override_by_type(
      rdma_cmq_submission_recovery_request::get_type(),
      rdma_cmq_factory_trap_recovery_request::get_type()
    );
    factory.set_type_override_by_type(
      rdma_cmq_reset_isolation_proof::get_type(),
      rdma_cmq_factory_trap_proof::get_type()
    );
    factory.set_type_override_by_type(
      rdma_hw_qpc_command_body::get_type(),
      rdma_cmq_factory_trap_qpc_body::get_type()
    );
    factory.set_type_override_by_type(
      rdma_hw_object_id_command_body::get_type(),
      rdma_cmq_factory_trap_object_body::get_type()
    );
    factory.set_type_override_by_type(
      rdma_hw_mr_deregister_body::get_type(),
      rdma_cmq_factory_trap_mr_body::get_type()
    );
    factory.set_type_override_by_type(
      rdma_hw_occ_flush_body::get_type(),
      rdma_cmq_factory_trap_occ_body::get_type()
    );
    factory.set_type_override_by_type(
      rdma_hw_cmq_empty_body::get_type(),
      rdma_cmq_factory_trap_empty_body::get_type()
    );
    factory.set_type_override_by_type(
      rdma_hw_cmq_completion::get_type(),
      rdma_cmq_factory_trap_payload::get_type()
    );
  endfunction

  // 功能：验证 stateless transport 的一次配置、identity 透传和委托后畸形
  //   envelope 修复契约。
  // 输入/输出及副作用：无参数；构造本地 binding/desc/observer 和两个
  //   scheduler 替身，调用 configure/submit_observed 并发布 UVM 断言。
  // 失败/边界：覆盖未配置、null/repeated configure、null result/status 和
  //   MMIO_MAYBE_VISIBLE；委托后未知 I/O 不得误报 PRE_SUBMIT_REJECTED。
  task automatic check_transport_facade_contract();
    rdma_cmq_transport transport;
    rdma_cmq_transport_scheduler_double scheduler;
    rdma_cmq_transport_scheduler_double rejected_scheduler;
    rdma_function_binding binding;
    rdma_doorbell_desc desc;
    rdma_cmq_transport_observer observer;
    rdma_doorbell_submission_result expected_result;
    rdma_doorbell_submission_result result;
    rdma_status expected_status;
    rdma_status status;

    transport = rdma_cmq_transport::type_id::create(
      "transport_contract"
    );
    scheduler = rdma_cmq_transport_scheduler_double::type_id::create(
      "transport_contract_scheduler"
    );
    rejected_scheduler =
      rdma_cmq_transport_scheduler_double::type_id::create(
        "transport_contract_rejected_scheduler"
      );
    binding = make_binding("transport_contract_binding", RDMA_BIND_ACTIVE);
    desc = rdma_doorbell_desc::type_id::create("transport_contract_desc");
    observer = new("transport_contract_observer");

    transport.submit_observed(binding, desc, observer, result);
    if (result == null || result.status == null) begin
      `uvm_error("TRANSPORT_UNCONFIGURED",
                 "unconfigured transport returned incomplete evidence")
    end
    else begin
      expect_status("TRANSPORT_UNCONFIGURED_STATUS", result.status,
                    RDMA_SC_INVALID_STATE);
      if (result.submission_effect !=
          RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED)
        `uvm_error("TRANSPORT_UNCONFIGURED_EFFECT",
                   "pre-delegation rejection reported the wrong effect")
    end

    status = transport.configure(null);
    expect_status("TRANSPORT_NULL_CONFIGURE", status,
                  RDMA_SC_INVALID_ARGUMENT);
    status = transport.configure(scheduler);
    expect_status("TRANSPORT_CONFIGURE", status, RDMA_SC_OK);
    status = transport.configure(rejected_scheduler);
    expect_status("TRANSPORT_RECONFIGURE", status, RDMA_SC_INVALID_STATE);

    expected_result = new("transport_forwarded_result");
    expected_result.status = rdma_status::make(
      RDMA_SC_TIMEOUT, "injected forwarded result"
    );
    expected_result.submission_effect =
      RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED;
    scheduler.response = expected_result;
    transport.submit_observed(binding, desc, observer, result);
    if (scheduler.submit_calls != 1 || rejected_scheduler.submit_calls != 0 ||
        scheduler.last_binding != binding || scheduler.last_desc != desc ||
        scheduler.last_observer != observer || result != expected_result ||
        observer.calls != 0)
      `uvm_error("TRANSPORT_FORWARD_IDENTITY",
                 "transport cloned, replaced, skipped or repeated a delegate")

    scheduler.return_null_result = 1'b1;
    transport.submit_observed(binding, desc, observer, result);
    if (result == null || result.status == null) begin
      `uvm_error("TRANSPORT_NULL_RESULT",
                 "null delegate result did not produce fallback evidence")
    end
    else begin
      expect_status("TRANSPORT_NULL_RESULT_STATUS", result.status,
                    RDMA_SC_INVALID_STATE);
      if (result.submission_effect != RDMA_SUBMIT_EFFECT_UNOBSERVED)
        `uvm_error("TRANSPORT_NULL_RESULT_EFFECT",
                   "null delegate result claimed a pre-submit observation")
    end

    scheduler.return_null_result = 1'b0;
    expected_result = new("transport_null_status_result");
    expected_result.status = null;
    expected_result.submission_effect =
      RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN;
    scheduler.response = expected_result;
    transport.submit_observed(binding, desc, observer, result);
    if (result != expected_result || result.status == null) begin
      `uvm_error("TRANSPORT_NULL_STATUS",
                 "null delegate status was not repaired in-place")
    end
    else begin
      expect_status("TRANSPORT_NULL_STATUS_VALUE", result.status,
                    RDMA_SC_INVALID_STATE);
      if (result.submission_effect !=
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN)
        `uvm_error("TRANSPORT_NULL_STATUS_EFFECT",
                   "null status repair lost the delegate scalar effect")
    end

    expected_result = new("transport_mmio_maybe_visible_result");
    expected_status = rdma_status::make(
      RDMA_SC_TIMEOUT, "injected MMIO maybe-visible result"
    );
    expected_result.status = expected_status;
    expected_result.submission_effect =
      RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE;
    scheduler.response = expected_result;
    transport.submit_observed(binding, desc, observer, result);
    if (scheduler.submit_calls != 4 || result != expected_result ||
        result.status != expected_status ||
        result.submission_effect !=
          RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE)
      `uvm_error("TRANSPORT_MMIO_MAYBE_VISIBLE",
                 "post-delegation evidence was cloned or downgraded")
  endtask

  // 功能：验证 engine 只在成功 prepare 提交新 transport，reset/shutdown 清除
  //   引用，并在后续 prepare 创建绑定新 scheduler 的不同对象。
  // 输入/输出及副作用：无参数；驱动两轮 prepare、reset/shutdown，mock 记录
  //   backing I/O，probe 只暴露 facade identity。
  // 失败/边界：profile 拒绝不得产生 I/O 或残留 facade；reset/reprepare 不得
  //   复用旧 facade 或把第二轮委托发送给第一轮 scheduler。
  task automatic check_transport_engine_lifecycle();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem first_mem;
    rdma_mock_host_mem second_mem;
    rdma_cmq_transport_scheduler_double first_scheduler;
    rdma_cmq_transport_scheduler_double second_scheduler;
    rdma_cmq_test_profile first_profile;
    rdma_cmq_test_profile second_profile;
    rdma_function_binding first_binding;
    rdma_function_binding second_binding;
    rdma_cmq first_cmq;
    rdma_cmq second_cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_transport first_transport;
    rdma_cmq_transport second_transport;
    rdma_doorbell_desc desc;
    rdma_cmq_transport_observer observer;
    rdma_doorbell_submission_result first_response;
    rdma_doorbell_submission_result second_response;
    rdma_doorbell_submission_result result;
    rdma_cmq_completion completions[$];
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "transport_lifecycle_engine"
    );
    first_mem = rdma_mock_host_mem::type_id::create(
      "transport_lifecycle_first_mem"
    );
    first_scheduler =
      rdma_cmq_transport_scheduler_double::type_id::create(
        "transport_lifecycle_first_scheduler"
      );
    first_profile = rdma_cmq_test_profile::type_id::create(
      "transport_lifecycle_first_profile"
    );
    first_binding = make_binding("transport_lifecycle_first_binding",
                                 RDMA_BIND_PREPARED);
    first_cmq = make_cmq("transport_lifecycle_first_cmq", first_binding);
    first_profile.fail_validation = 1'b1;
    engine.prepare(first_binding, first_cmq, 1'b1, 20'h34567, first_mem,
                   first_scheduler, first_profile, runtime_desc, status);
    expect_status("TRANSPORT_FAILED_PREPARE", status,
                  RDMA_SC_INVALID_STATE);
    if (runtime_desc != null || engine.transport_reference() != null ||
        first_mem.calls.size() != 0)
      `uvm_error("TRANSPORT_FAILED_PREPARE_ATOMIC",
                 "failed prepare retained a facade or performed I/O")

    first_profile.fail_validation = 1'b0;
    prepare_defaults("TRANSPORT_FIRST_PREPARE", engine, first_mem,
                     first_binding, first_cmq, first_scheduler,
                     first_profile, runtime_desc);
    first_transport = engine.transport_reference();
    if (first_transport == null)
      `uvm_error("TRANSPORT_FIRST_INSTALL",
                 "successful prepare did not install a transport")
    desc = rdma_doorbell_desc::type_id::create(
      "transport_lifecycle_desc"
    );
    observer = new("transport_lifecycle_observer");
    first_response = new("transport_lifecycle_first_response");
    first_response.status = rdma_status::success();
    first_scheduler.response = first_response;
    if (first_transport != null)
      first_transport.submit_observed(first_binding, desc, observer, result);
    if (first_scheduler.submit_calls != 1 || result != first_response)
      `uvm_error("TRANSPORT_FIRST_SCHEDULER",
                 "first prepared facade is not configured to first scheduler")

    engine.reset(completions, status);
    expect_status("TRANSPORT_RESET", status, RDMA_SC_OK);
    if (engine.transport_reference() != null)
      `uvm_error("TRANSPORT_RESET_CLEAR",
                 "reset retained the installed transport")

    second_mem = rdma_mock_host_mem::type_id::create(
      "transport_lifecycle_second_mem"
    );
    second_scheduler =
      rdma_cmq_transport_scheduler_double::type_id::create(
        "transport_lifecycle_second_scheduler"
      );
    second_profile = rdma_cmq_test_profile::type_id::create(
      "transport_lifecycle_second_profile"
    );
    second_binding = make_binding("transport_lifecycle_second_binding",
                                  RDMA_BIND_PREPARED);
    second_binding.function_uid++;
    second_binding.global_function_id++;
    second_binding.generation++;
    second_binding.synchronize_identity_from_legacy_mirrors();
    second_binding.owner_h = second_binding.make_handle();
    second_cmq = make_cmq("transport_lifecycle_second_cmq",
                          second_binding);
    prepare_defaults("TRANSPORT_SECOND_PREPARE", engine, second_mem,
                     second_binding, second_cmq, second_scheduler,
                     second_profile, runtime_desc);
    second_transport = engine.transport_reference();
    if (second_transport == null || second_transport == first_transport)
      `uvm_error("TRANSPORT_REPREPARE_IDENTITY",
                 "reprepare omitted or reused the old transport")
    second_response = new("transport_lifecycle_second_response");
    second_response.status = rdma_status::success();
    second_scheduler.response = second_response;
    if (second_transport != null)
      second_transport.submit_observed(second_binding, desc, observer,
                                       result);
    if (second_scheduler.submit_calls != 1 ||
        first_scheduler.submit_calls != 1 || result != second_response)
      `uvm_error("TRANSPORT_SECOND_SCHEDULER",
                 "reprepared facade reused the old scheduler")

    engine.shutdown(status);
    expect_status("TRANSPORT_SHUTDOWN", status, RDMA_SC_OK);
    if (engine.transport_reference() != null)
      `uvm_error("TRANSPORT_SHUTDOWN_CLEAR",
                 "shutdown retained the installed transport")
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_success_and_detachment 中构造或驱动“success and detachment”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_success_and_detachment();
    rdma_cmq_engine engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping first_snapshot;
    rdma_dma_mapping second_snapshot;
    rdma_status status;

    engine = rdma_cmq_engine::type_id::create("success_engine");
    mem = rdma_mock_host_mem::type_id::create("success_mem");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "success_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("success_profile");
    prepared_binding = make_binding("prepared_binding", RDMA_BIND_PREPARED);
    active_binding = make_binding("active_binding", RDMA_BIND_ACTIVE);
    cmq = make_cmq("success_cmq", prepared_binding);

    if (engine.state() != RDMA_CMQ_ENGINE_UNCONFIGURED ||
        engine.published_count() != 0 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0 ||
        engine.mapping_snapshot() != null)
      `uvm_error("CMQ_INITIAL_STATE", "new engine state is not empty")

    engine.prepare(prepared_binding, cmq, 1'b1, 20'h34567,
                   mem, scheduler, profile, runtime_desc, status);
    expect_status("PREPARE", status, RDMA_SC_OK);
    if (engine.state() != RDMA_CMQ_ENGINE_PREPARED)
      `uvm_error("PREPARE_STATE", "prepare did not enter PREPARED")
    if (runtime_desc == null)
      `uvm_error("PREPARE_RUNTIME", "prepare returned no runtime descriptor")
    else begin
      expect_status("PREPARE_RUNTIME_VALIDATE", runtime_desc.validate(),
                    RDMA_SC_OK);
      if (runtime_desc.sq_iova.value !=
            mem.regions[0].mapping.iova.value ||
          runtime_desc.cq_iova.value !=
            mem.regions[0].mapping.iova.value + 64'd2048)
        `uvm_error("CMQ_LAYOUT", "runtime IOVA layout is incorrect")
      if (runtime_desc.sq_depth != 32 || runtime_desc.cq_depth != 32 ||
          runtime_desc.entry_bytes != 64 ||
          !runtime_desc.initial_sq_valid ||
          !runtime_desc.initial_cq_owner ||
          runtime_desc.initial_doorbell_polarity)
        `uvm_error("CMQ_RUNTIME_INIT",
                   "runtime descriptor initialization is incorrect")
      if (runtime_desc.function_h == prepared_binding.owner_h ||
          runtime_desc.cmq_h == cmq.handle)
        `uvm_error("CMQ_RUNTIME_DETACH",
                   "runtime descriptor aliases caller authority")
    end

    if (mem.calls.size() != 2 ||
        count_host_calls(mem, "allocate") != 1 ||
        count_host_calls(mem, "write") != 1 ||
        mem.calls[0].size != 4096 || mem.calls[0].alignment != 4096 ||
        mem.calls[0].direction != RDMA_DMA_BIDIRECTIONAL ||
        mem.calls[0].request_context == null ||
        mem.calls[0].request_context.function_h == null ||
        !mem.calls[0].request_context.function_h.same_instance(
          prepared_binding.make_handle()
        ) || mem.calls[0].request_context.requester_bdf == '0 ||
        mem.calls[0].request_context.requester_bdf !=
          prepared_binding.pcie.bdf ||
        !mem.calls[0].request_context.pasid_valid ||
        mem.calls[0].request_context.pasid != 20'h34567 ||
        mem.calls[0].request_context.owner_h == null ||
        !mem.calls[0].request_context.owner_h.same_instance(cmq.handle))
      `uvm_error("CMQ_ALLOCATE",
                 "prepare allocation request/context is incorrect")
    if (mem.calls.size() >= 2 &&
        (mem.calls[1].method_name != "write" ||
         mem.calls[1].offset != 0 || mem.calls[1].data.size() != 4096))
      `uvm_error("CMQ_ZERO_WRITE", "prepare did not issue one 4096B write")
    if (mem.regions.size() != 1 || mem.regions[0].data.size() != 4096)
      `uvm_error("CMQ_ZERO_REGION", "prepare allocated wrong backing size")
    else begin
      foreach (mem.regions[0].data[i]) begin
        if (mem.regions[0].data[i] != 0)
          `uvm_error("CMQ_ZERO_REGION",
                     $sformatf("backing byte %0d was not zero", i))
      end
    end

    first_snapshot = engine.mapping_snapshot();
    second_snapshot = engine.mapping_snapshot();
    if (first_snapshot == null || second_snapshot == null ||
        first_snapshot == second_snapshot ||
        first_snapshot == mem.regions[0].mapping)
      `uvm_error("CMQ_MAPPING_SNAPSHOT",
                 "mapping query did not return detached snapshots")
    else begin
      first_snapshot.pasid = '0;
      if (second_snapshot.pasid != 20'h34567 ||
          engine.mapping_snapshot().pasid != 20'h34567)
        `uvm_error("CMQ_MAPPING_SNAPSHOT",
                   "mapping snapshot mutation reached engine authority")
    end
    if (engine.published_count() != 0 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0)
      `uvm_error("CMQ_PREPARE_COUNTS", "prepare changed ring counters")

    prepared_binding.function_uid = '0;
    prepared_binding.pcie.bdf = '0;
    cmq.handle.object_id = '0;
    cmq.depth = 64;
    if (runtime_desc != null) begin
      runtime_desc.sq_iova.value = '0;
      runtime_desc.function_h.generation = '0;
      runtime_desc.cmq_h.object_id = '0;
    end
    engine.activate(active_binding, status);
    expect_status("ACTIVATE_DETACHED_INPUTS", status, RDMA_SC_OK);
    if (engine.state() != RDMA_CMQ_ENGINE_ACTIVE)
      `uvm_error("ACTIVATE_STATE", "activate did not enter ACTIVE")
    engine.activate(active_binding, status);
    expect_status("ACTIVATE_ALREADY_ACTIVE", status,
                  RDMA_SC_INVALID_STATE);

    engine.shutdown(status);
    expect_status("SUCCESS_SHUTDOWN", status, RDMA_SC_OK);
    expect_unconfigured("SUCCESS_SHUTDOWN_STATE", engine);
    if (count_host_calls(mem, "release") != 1)
      `uvm_error("SUCCESS_SHUTDOWN_RELEASE",
                 "shutdown did not release backing exactly once")
    engine.shutdown(status);
    expect_status("SUCCESS_SHUTDOWN_IDEMPOTENT", status, RDMA_SC_OK);
    if (count_host_calls(mem, "release") != 1)
      `uvm_error("SUCCESS_SHUTDOWN_IDEMPOTENT",
                 "idempotent shutdown released backing again")
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_preallocation_rejections 中构造或驱动“preallocation rejections”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_preallocation_rejections();
    rdma_cmq_engine engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_status status;

    scheduler = rdma_doorbell_scheduler::type_id::create("reject_scheduler");

    mem = rdma_mock_host_mem::type_id::create("null_binding_mem");
    profile = rdma_cmq_test_profile::type_id::create("null_binding_profile");
    binding = make_binding("null_binding_reference", RDMA_BIND_PREPARED);
    cmq = make_cmq("null_binding_cmq", binding);
    engine = rdma_cmq_engine::type_id::create("null_binding_engine");
    engine.prepare(null, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("NULL_BINDING", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("NULL_BINDING_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("null_cmq_mem");
    binding = make_binding("null_cmq_binding", RDMA_BIND_PREPARED);
    engine = rdma_cmq_engine::type_id::create("null_cmq_engine");
    engine.prepare(binding, null, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("NULL_CMQ", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("NULL_CMQ_STATE", engine);

    binding = make_binding("null_adapter_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("null_adapter_cmq", binding);
    engine = rdma_cmq_engine::type_id::create("null_adapter_engine");
    engine.prepare(binding, cmq, 1'b0, '0, null, scheduler, profile,
                   runtime_desc, status);
    expect_status("NULL_HOST_MEM", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("NULL_HOST_MEM_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("null_scheduler_mem");
    engine = rdma_cmq_engine::type_id::create("null_scheduler_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, null, profile,
                   runtime_desc, status);
    expect_status("NULL_SCHEDULER", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("NULL_SCHEDULER_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("null_profile_mem");
    engine = rdma_cmq_engine::type_id::create("null_profile_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, null,
                   runtime_desc, status);
    expect_status("NULL_PROFILE", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("NULL_PROFILE_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("wrong_lifecycle_mem");
    binding = make_binding("wrong_lifecycle_binding", RDMA_BIND_ACTIVE);
    cmq = make_cmq("wrong_lifecycle_cmq", binding);
    engine = rdma_cmq_engine::type_id::create("wrong_lifecycle_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("BINDING_NOT_PREPARED", status, RDMA_SC_INVALID_STATE);
    expect_unconfigured("BINDING_NOT_PREPARED_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("invalid_binding_mem");
    binding = make_binding("invalid_binding", RDMA_BIND_PREPARED);
    binding.pcie = null;
    cmq = make_cmq("invalid_binding_cmq", binding);
    engine = rdma_cmq_engine::type_id::create("invalid_binding_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("INVALID_BINDING", status, RDMA_SC_INVALID_STATE);
    expect_unconfigured("INVALID_BINDING_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("binding_owner_mem");
    binding = make_binding("binding_owner_binding", RDMA_BIND_PREPARED);
    binding.owner_h.object_id++;
    cmq = make_cmq("binding_owner_cmq", binding);
    engine = rdma_cmq_engine::type_id::create("binding_owner_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("BINDING_OWNER", status, RDMA_SC_INVALID_STATE);
    expect_unconfigured("BINDING_OWNER_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("cmq_depth_mem");
    binding = make_binding("cmq_depth_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("cmq_depth_cmq", binding, 64);
    engine = rdma_cmq_engine::type_id::create("cmq_depth_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("CMQ_DEPTH", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("CMQ_DEPTH_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("cmq_handle_mem");
    cmq = make_cmq("cmq_handle_cmq", binding);
    cmq.handle = null;
    engine = rdma_cmq_engine::type_id::create("cmq_handle_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("CMQ_HANDLE", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("CMQ_HANDLE_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("cmq_owner_mem");
    cmq = make_cmq("cmq_owner_cmq", binding);
    cmq.owner = null;
    engine = rdma_cmq_engine::type_id::create("cmq_owner_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("CMQ_OWNER", status, RDMA_SC_INVALID_ARGUMENT);
    expect_unconfigured("CMQ_OWNER_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("cmq_state_mem");
    cmq = make_cmq("cmq_state_cmq", binding);
    cmq.state = RDMA_RESOURCE_RELEASED;
    engine = rdma_cmq_engine::type_id::create("cmq_state_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("CMQ_LIFECYCLE", status, RDMA_SC_INVALID_STATE);
    expect_unconfigured("CMQ_LIFECYCLE_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("profile_failure_mem");
    profile = rdma_cmq_test_profile::type_id::create("failure_profile");
    profile.fail_validation = 1'b1;
    cmq = make_cmq("profile_failure_cmq", binding);
    engine = rdma_cmq_engine::type_id::create("profile_failure_engine");
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("PROFILE_FAILURE", status, RDMA_SC_INVALID_STATE);
    if (profile.validation_calls != 1 || mem.calls.size() != 0)
      `uvm_error("PROFILE_BEFORE_ALLOCATE",
                 "profile failure did not precede allocation")
    expect_unconfigured("PROFILE_FAILURE_STATE", engine);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_pasid_normalization_and_busy_prepare 中构造或驱动“pasid normalization and busy
  //   prepare”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_pasid_normalization_and_busy_prepare();
    rdma_cmq_engine engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_status status;
    int unsigned calls_before;

    engine = rdma_cmq_engine::type_id::create("pasid_engine");
    mem = rdma_mock_host_mem::type_id::create("pasid_mem");
    scheduler = rdma_doorbell_scheduler::type_id::create("pasid_scheduler");
    profile = rdma_cmq_test_profile::type_id::create("pasid_profile");
    binding = make_binding("pasid_binding", RDMA_BIND_PREPARED);
    binding.queue_dma.pasid_valid = 1'b0;
    binding.queue_dma.pasid = '0;
    cmq = make_cmq("pasid_cmq", binding);
    engine.prepare(binding, cmq, 1'b0, 20'hfffff, mem, scheduler,
                   profile, runtime_desc, status);
    expect_status("PASID_NORMALIZE", status, RDMA_SC_OK);
    if (mem.calls[0].request_context.pasid_valid ||
        mem.calls[0].request_context.pasid != 0 ||
        mem.regions[0].mapping.pasid_valid ||
        mem.regions[0].mapping.pasid != 0)
      `uvm_error("PASID_NORMALIZE",
                 "invalid PASID was not normalized to zero")

    calls_before = mem.calls.size();
    engine.prepare(binding, cmq, 1'b0, '0, mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("PREPARE_ALREADY_PREPARED", status,
                  RDMA_SC_INVALID_STATE);
    if (runtime_desc != null || mem.calls.size() != calls_before)
      `uvm_error("PREPARE_ALREADY_PREPARED",
                 "busy prepare changed outputs or host memory")
    engine.shutdown(status);
    expect_status("PASID_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_allocation_and_rollback_failures 中构造或驱动“allocation and rollback
  //   failures”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_allocation_and_rollback_failures();
    rdma_cmq_engine engine;
    rdma_cmq_engine_probe release_failure_engine;
    rdma_cmq_runtime_clone_failure_engine clone_failure_engine;
    rdma_cmq_runtime_build_failure_engine build_failure_engine;
    rdma_mock_host_mem mem;
    rdma_cmq_short_mapping_mem short_mem;
    rdma_cmq_bad_mapping_mem bad_mem;
    rdma_cmq_upper_boundary_mem upper_boundary_mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping retained_snapshot;
    rdma_mock_dma_mapping retained_mock;
    rdma_status status;

    scheduler = rdma_doorbell_scheduler::type_id::create(
      "rollback_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("rollback_profile");
    binding = make_binding("rollback_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("rollback_cmq", binding);

    mem = rdma_mock_host_mem::type_id::create("allocate_failure_mem");
    expect_status("ARM_ALLOCATE_FAILURE",
                  mem.fail_next("allocate", rdma_status::make(
                    RDMA_SC_RESOURCE_EXHAUSTED, "injected allocate failure"
                  )), RDMA_SC_OK);
    engine = rdma_cmq_engine::type_id::create("allocate_failure_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567, mem, scheduler,
                   profile, runtime_desc, status);
    expect_status("ALLOCATE_FAILURE", status, RDMA_SC_RESOURCE_EXHAUSTED);
    if (count_host_calls(mem, "allocate") != 1 ||
        count_host_calls(mem, "write") != 0 ||
        count_host_calls(mem, "release") != 0)
      `uvm_error("ALLOCATE_FAILURE_CALLS",
                 "allocate failure performed later host operations")
    expect_unconfigured("ALLOCATE_FAILURE_STATE", engine);

    short_mem = rdma_cmq_short_mapping_mem::type_id::create("short_mem");
    engine = rdma_cmq_engine::type_id::create("short_mapping_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567, short_mem, scheduler,
                   profile, runtime_desc, status);
    expect_status("SHORT_MAPPING", status, RDMA_SC_INVALID_STATE);
    if (count_host_calls(short_mem, "allocate") != 1 ||
        count_host_calls(short_mem, "write") != 0 ||
        count_host_calls(short_mem, "release") +
          count_host_calls(short_mem, "release_opaque") != 1)
      `uvm_error("SHORT_MAPPING_ROLLBACK",
                 "invalid mapping was not released exactly once")
    expect_unconfigured("SHORT_MAPPING_STATE", engine);

    for (int unsigned bad_kind = RDMA_CMQ_BAD_MAPPING_ATOMIC;
         bad_kind <= RDMA_CMQ_BAD_MAPPING_BACKING_RANGE; bad_kind++) begin
      bad_mem = rdma_cmq_bad_mapping_mem::type_id::create(
        $sformatf("bad_mapping_mem_%0d", bad_kind)
      );
      bad_mem.bad_kind = rdma_cmq_bad_mapping_kind_e'(bad_kind);
      engine = rdma_cmq_engine::type_id::create(
        $sformatf("bad_mapping_engine_%0d", bad_kind)
      );
      engine.prepare(binding, cmq, 1'b1, 20'h34567, bad_mem, scheduler,
                     profile, runtime_desc, status);
      if (bad_kind == RDMA_CMQ_BAD_MAPPING_ATOMIC)
        expect_status("ATOMIC_MAPPING_PREPARE", status,
                      RDMA_SC_DMA_PERMISSION);
      else
        expect_status($sformatf("BAD_MAPPING_PREPARE_%0d", bad_kind),
                      status, RDMA_SC_DMA_TRANSLATION);
      if (bad_kind inside {RDMA_CMQ_BAD_MAPPING_IOVA_RANGE,
                           RDMA_CMQ_BAD_MAPPING_BACKING_RANGE}) begin
        // A 4096-aligned 64-bit base cannot overflow a 4096-byte range.
        // The first address above the maximum legal aligned base is
        // necessarily unaligned, so fail closed at the alignment check.
        if (status == null ||
            status.message !=
              "CMQ backing mapping is not 4096-byte aligned")
          `uvm_error("BAD_MAPPING_UPPER_BOUND_STATUS",
                     "upper-bound fixture did not fail on alignment")
      end
      expect_post_allocate_rollback(
        $sformatf("BAD_MAPPING_ROLLBACK_%0d", bad_kind), engine,
        bad_mem, runtime_desc, 0
      );
    end

    upper_boundary_mem = rdma_cmq_upper_boundary_mem::type_id::create(
      "upper_boundary_mem"
    );
    engine = rdma_cmq_engine::type_id::create("upper_boundary_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567,
                   upper_boundary_mem, scheduler, profile,
                   runtime_desc, status);
    expect_status("UPPER_BOUNDARY_PREPARE", status, RDMA_SC_OK);
    if (runtime_desc == null)
      `uvm_error("UPPER_BOUNDARY_RUNTIME",
                 "maximum legal aligned base published no runtime")
    else begin
      expect_status("UPPER_BOUNDARY_RUNTIME_VALIDATE",
                    runtime_desc.validate(), RDMA_SC_OK);
      if (runtime_desc.sq_iova.value != 64'hffff_ffff_ffff_f000 ||
          runtime_desc.cq_iova.value != 64'hffff_ffff_ffff_f800)
        `uvm_error("UPPER_BOUNDARY_LAYOUT",
                   "maximum legal aligned base produced wrong layout")
    end
    if (count_host_calls(upper_boundary_mem, "allocate") != 1 ||
        count_host_calls(upper_boundary_mem, "write") != 1 ||
        count_host_calls(upper_boundary_mem, "release") != 0)
      `uvm_error("UPPER_BOUNDARY_CALLS",
                 "maximum legal aligned base used wrong host operations")
    engine.shutdown(status);
    expect_status("UPPER_BOUNDARY_SHUTDOWN", status, RDMA_SC_OK);
    expect_unconfigured("UPPER_BOUNDARY_SHUTDOWN_STATE", engine);
    if (count_host_calls(upper_boundary_mem, "release") != 1)
      `uvm_error("UPPER_BOUNDARY_RELEASE",
                 "maximum legal aligned base was not released once")

    mem = rdma_mock_host_mem::type_id::create("write_failure_mem");
    expect_status("ARM_WRITE_FAILURE",
                  mem.fail_next("write", rdma_status::make(
                    RDMA_SC_DMA_TRANSLATION, "injected zero write failure"
                  )), RDMA_SC_OK);
    engine = rdma_cmq_engine::type_id::create("write_failure_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567, mem, scheduler,
                   profile, runtime_desc, status);
    expect_status("ZERO_WRITE_FAILURE", status, RDMA_SC_DMA_TRANSLATION);
    if (count_host_calls(mem, "allocate") != 1 ||
        count_host_calls(mem, "write") != 1 ||
        count_host_calls(mem, "release") != 1)
      `uvm_error("ZERO_WRITE_ROLLBACK",
                 "zero-write failure did not release exactly once")
    expect_unconfigured("ZERO_WRITE_FAILURE_STATE", engine);

    mem = rdma_mock_host_mem::type_id::create("build_failure_mem");
    build_failure_engine =
      rdma_cmq_runtime_build_failure_engine::type_id::create(
        "build_failure_engine"
      );
    build_failure_engine.prepare(binding, cmq, 1'b1, 20'h34567,
                                 mem, scheduler, profile,
                                 runtime_desc, status);
    expect_status("RUNTIME_BUILD_FAILURE", status, RDMA_SC_CODEC_ERROR);
    expect_post_allocate_rollback("RUNTIME_BUILD_ROLLBACK",
                                  build_failure_engine, mem,
                                  runtime_desc, 1);

    mem = rdma_mock_host_mem::type_id::create("build_null_status_mem");
    build_failure_engine =
      rdma_cmq_runtime_build_failure_engine::type_id::create(
        "build_null_status_engine"
      );
    build_failure_engine.return_null_status = 1'b1;
    build_failure_engine.prepare(binding, cmq, 1'b1, 20'h34567,
                                 mem, scheduler, profile,
                                 runtime_desc, status);
    expect_status("RUNTIME_BUILD_NULL_STATUS", status,
                  RDMA_SC_INVALID_STATE);
    expect_post_allocate_rollback("RUNTIME_BUILD_NULL_ROLLBACK",
                                  build_failure_engine, mem,
                                  runtime_desc, 1);

    mem = rdma_mock_host_mem::type_id::create("clone_failure_mem");
    clone_failure_engine =
      rdma_cmq_runtime_clone_failure_engine::type_id::create(
        "clone_failure_engine"
      );
    clone_failure_engine.prepare(binding, cmq, 1'b1, 20'h34567,
                                 mem, scheduler, profile,
                                 runtime_desc, status);
    expect_status("RUNTIME_CLONE_FAILURE", status, RDMA_SC_INVALID_STATE);
    expect_post_allocate_rollback("RUNTIME_CLONE_ROLLBACK",
                                  clone_failure_engine, mem,
                                  runtime_desc, 1);

    mem = rdma_mock_host_mem::type_id::create("release_failure_mem");
    expect_status("ARM_RELEASE_WRITE_FAILURE",
                  mem.fail_next("write", rdma_status::make(
                    RDMA_SC_DMA_TRANSLATION, "rollback trigger"
                  )), RDMA_SC_OK);
    expect_status("ARM_RELEASE_FAILURE",
                  mem.fail_next("release", rdma_status::make(
                    RDMA_SC_UNKNOWN_HW_ERROR,
                    "injected rollback release failure"
                  )), RDMA_SC_OK);
    release_failure_engine = rdma_cmq_engine_probe::type_id::create(
      "release_failure_engine"
    );
    release_failure_engine.prepare(binding, cmq, 1'b1, 20'h34567, mem,
                                   scheduler, profile, runtime_desc,
                                   status);
    expect_status("ROLLBACK_RELEASE_FAILURE", status,
                  RDMA_SC_UNKNOWN_HW_ERROR);
    retained_snapshot = release_failure_engine.mapping_snapshot();
    if (status == null ||
        status.message !=
          {"CMQ prepare rollback release failed: ",
           "injected rollback release failure; original failure: ",
           "rollback trigger"} ||
        !release_failure_engine.retry_only_poisoned() ||
        retained_snapshot == null ||
        count_host_calls(mem, "release") != 1)
      `uvm_error("ROLLBACK_RELEASE_AUTHORITY",
                 "failed rollback did not retain POISONED authority")
    if (!$cast(retained_mock, retained_snapshot))
      `uvm_error("ROLLBACK_RELEASE_AUTHORITY",
                 "failed rollback lost allocation identity")
    release_failure_engine.shutdown(status);
    expect_status("ROLLBACK_RELEASE_RETRY", status, RDMA_SC_OK);
    expect_unconfigured("ROLLBACK_RELEASE_RETRY_STATE",
                        release_failure_engine);
    if (count_host_calls(mem, "release") != 2)
      `uvm_error("ROLLBACK_RELEASE_RETRY",
                 "shutdown did not retry the retained release once")
    expect_release_retry_identity("ROLLBACK_RELEASE_RETRY_IDENTITY", mem,
                                  retained_mock);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_null_status_guards 中构造或驱动“null status guards”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_null_status_guards();
    rdma_cmq_engine engine;
    rdma_mock_host_mem mem;
    rdma_cmq_allocate_result_mem allocate_mem;
    rdma_cmq_null_write_mem null_write_mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_status status;

    scheduler = rdma_doorbell_scheduler::type_id::create(
      "null_status_scheduler"
    );
    binding = make_binding("null_status_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("null_status_cmq", binding);

    mem = rdma_mock_host_mem::type_id::create("null_profile_mem");
    profile = rdma_cmq_test_profile::type_id::create(
      "null_status_profile"
    );
    profile.return_null_status = 1'b1;
    engine = rdma_cmq_engine::type_id::create("null_profile_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567, mem, scheduler,
                   profile, runtime_desc, status);
    expect_status("NULL_PROFILE_STATUS", status, RDMA_SC_INVALID_STATE);
    if (status == null ||
        status.message != "CMQ hardware profile returned null status" ||
        profile.validation_calls != 1 || runtime_desc != null ||
        mem.calls.size() != 0)
      `uvm_error("NULL_PROFILE_STATUS",
                 "null profile status did not fail before allocation")
    expect_unconfigured("NULL_PROFILE_STATUS_STATE", engine);

    profile = rdma_cmq_test_profile::type_id::create(
      "null_status_good_profile"
    );
    allocate_mem = rdma_cmq_allocate_result_mem::type_id::create(
      "null_allocate_no_candidate_mem"
    );
    allocate_mem.result_kind = RDMA_CMQ_ALLOCATE_NULL_NO_CANDIDATE;
    engine = rdma_cmq_engine::type_id::create(
      "null_allocate_no_candidate_engine"
    );
    engine.prepare(binding, cmq, 1'b1, 20'h34567, allocate_mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("NULL_ALLOCATE_NO_CANDIDATE", status,
                  RDMA_SC_INVALID_STATE);
    if (status == null ||
        status.message != "CMQ host allocation returned null status" ||
        runtime_desc != null || allocate_mem.regions.size() != 0 ||
        count_host_calls(allocate_mem, "allocate") != 1 ||
        count_host_calls(allocate_mem, "write") != 0 ||
        count_host_calls(allocate_mem, "release") != 0)
      `uvm_error("NULL_ALLOCATE_NO_CANDIDATE",
                 "null allocation without candidate did not fail closed")
    expect_unconfigured("NULL_ALLOCATE_NO_CANDIDATE_STATE", engine);

    allocate_mem = rdma_cmq_allocate_result_mem::type_id::create(
      "null_allocate_candidate_mem"
    );
    allocate_mem.result_kind = RDMA_CMQ_ALLOCATE_NULL_WITH_CANDIDATE;
    engine = rdma_cmq_engine::type_id::create(
      "null_allocate_candidate_engine"
    );
    engine.prepare(binding, cmq, 1'b1, 20'h34567, allocate_mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("NULL_ALLOCATE_WITH_CANDIDATE", status,
                  RDMA_SC_INVALID_STATE);
    if (status == null ||
        status.message != "CMQ host allocation returned null status")
      `uvm_error("NULL_ALLOCATE_WITH_CANDIDATE",
                 "null allocation candidate lost normalized status")
    expect_post_allocate_rollback("NULL_ALLOCATE_CANDIDATE_ROLLBACK",
                                  engine, allocate_mem, runtime_desc, 0);

    allocate_mem = rdma_cmq_allocate_result_mem::type_id::create(
      "failed_allocate_candidate_mem"
    );
    allocate_mem.result_kind = RDMA_CMQ_ALLOCATE_FAILURE_WITH_CANDIDATE;
    engine = rdma_cmq_engine::type_id::create(
      "failed_allocate_candidate_engine"
    );
    engine.prepare(binding, cmq, 1'b1, 20'h34567, allocate_mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("FAILED_ALLOCATE_WITH_CANDIDATE", status,
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (status == null ||
        status.message != "injected allocation failure with candidate")
      `uvm_error("FAILED_ALLOCATE_WITH_CANDIDATE",
                 "allocation candidate failure lost adapter status")
    expect_post_allocate_rollback("FAILED_ALLOCATE_CANDIDATE_ROLLBACK",
                                  engine, allocate_mem, runtime_desc, 0);

    null_write_mem = rdma_cmq_null_write_mem::type_id::create(
      "null_write_mem"
    );
    engine = rdma_cmq_engine::type_id::create("null_write_engine");
    engine.prepare(binding, cmq, 1'b1, 20'h34567, null_write_mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("NULL_WRITE_STATUS", status, RDMA_SC_INVALID_STATE);
    if (status == null ||
        status.message != "CMQ backing zero-write returned null status")
      `uvm_error("NULL_WRITE_STATUS",
                 "null write did not return normalized status")
    expect_post_allocate_rollback("NULL_WRITE_ROLLBACK", engine,
                                  null_write_mem, runtime_desc, 1);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_activation_guards 中构造或驱动“activation guards”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_activation_guards();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_function_binding candidate;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping good_mapping;
    rdma_dma_mapping before_mapping;
    rdma_dma_mapping after_mapping;
    rdma_status status;
    rdma_status_code_e expected_codes[RDMA_CMQ_TAMPER_COUNT];

    engine = rdma_cmq_engine_probe::type_id::create("activate_engine");
    mem = rdma_mock_host_mem::type_id::create("activate_mem");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "activate_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("activate_profile");
    prepared_binding = make_binding("activate_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("activate_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("activate_cmq", prepared_binding);
    prepare_defaults("ACTIVATE_PREPARE", engine, mem, prepared_binding,
                     cmq, scheduler, profile, runtime_desc);

    expected_codes[RDMA_CMQ_TAMPER_FUNCTION_KIND] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_FUNCTION_UID] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_FUNCTION_OBJECT] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_FUNCTION_GENERATION] =
      RDMA_SC_STALE_GENERATION;
    expected_codes[RDMA_CMQ_TAMPER_BDF] = RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_PASID_VALID] = RDMA_SC_DMA_PERMISSION;
    expected_codes[RDMA_CMQ_TAMPER_PASID] = RDMA_SC_DMA_PERMISSION;
    expected_codes[RDMA_CMQ_TAMPER_DMA_DOMAIN_VALID] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_DMA_DOMAIN] = RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_OWNER_NULL] = RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_OWNER_KIND] = RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_OWNER_UID] = RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_OWNER_OBJECT] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_OWNER_GENERATION] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_DIRECTION] = RDMA_SC_INVALID_STATE;
    expected_codes[RDMA_CMQ_TAMPER_STATE] = RDMA_SC_INVALID_STATE;
    expected_codes[RDMA_CMQ_TAMPER_SIZE] = RDMA_SC_INVALID_STATE;
    expected_codes[RDMA_CMQ_TAMPER_PERMISSION_READ] =
      RDMA_SC_DMA_PERMISSION;
    expected_codes[RDMA_CMQ_TAMPER_PERMISSION_WRITE] =
      RDMA_SC_DMA_PERMISSION;
    expected_codes[RDMA_CMQ_TAMPER_IOVA_ALIGNMENT] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_BACKING_ALIGNMENT] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_IOVA_RANGE] = RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_BACKING_RANGE] =
      RDMA_SC_DMA_TRANSLATION;
    expected_codes[RDMA_CMQ_TAMPER_PERMISSION_ATOMIC] =
      RDMA_SC_DMA_PERMISSION;

    candidate = make_binding("not_active_candidate", RDMA_BIND_PREPARED);
    engine.activate(candidate, status);
    expect_status("ACTIVATE_NOT_ACTIVE", status, RDMA_SC_INVALID_STATE);

    candidate = make_binding("uid_candidate", RDMA_BIND_ACTIVE);
    candidate.function_uid++;
    candidate.owner_h = candidate.make_handle();
    engine.activate(candidate, status);
    expect_status("ACTIVATE_UID", status, RDMA_SC_INVALID_ARGUMENT);

    candidate = make_binding("object_candidate", RDMA_BIND_ACTIVE);
    candidate.global_function_id++;
    candidate.owner_h = candidate.make_handle();
    engine.activate(candidate, status);
    expect_status("ACTIVATE_OBJECT", status, RDMA_SC_INVALID_ARGUMENT);

    candidate = make_binding("generation_candidate", RDMA_BIND_ACTIVE);
    candidate.generation++;
    candidate.synchronize_identity_from_legacy_mirrors();
    candidate.owner_h = candidate.make_handle();
    engine.activate(candidate, status);
    expect_status("ACTIVATE_GENERATION", status,
                  RDMA_SC_STALE_GENERATION);

    candidate = make_binding("bdf_candidate", RDMA_BIND_ACTIVE);
    candidate.pcie.bdf.bus++;
    candidate.queue_dma.requester_bdf = candidate.pcie.bdf;
    candidate.synchronize_identity_from_legacy_mirrors();
    engine.activate(candidate, status);
    expect_status("ACTIVATE_BDF", status, RDMA_SC_DMA_TRANSLATION);

    good_mapping = engine.mapping_snapshot();
    for (int unsigned kind = 0; kind < RDMA_CMQ_TAMPER_COUNT; kind++) begin
      engine.tamper_mapping(rdma_cmq_mapping_tamper_e'(kind));
      before_mapping = engine.mapping_snapshot();
      engine.activate(active_binding, status);
      expect_status($sformatf("ACTIVATE_MAPPING_%0d", kind), status,
                    expected_codes[kind]);
      after_mapping = engine.mapping_snapshot();
      if (engine.state() != RDMA_CMQ_ENGINE_PREPARED ||
          engine.published_count() != 0 || engine.retired_count() != 0 ||
          engine.cq_consumed_count() != 0)
        `uvm_error("ACTIVATE_MAPPING_ATOMIC",
                   "failed activate changed state or counters")
      if (!same_mapping_fields(before_mapping, after_mapping))
        `uvm_error("ACTIVATE_MAPPING_AUTHORITY",
                   "failed activate changed retained mapping authority")
      engine.restore_mapping(good_mapping);
    end

    engine.activate(active_binding, status);
    expect_status("ACTIVATE_SUCCESS", status, RDMA_SC_OK);
    if (engine.state() != RDMA_CMQ_ENGINE_ACTIVE)
      `uvm_error("ACTIVATE_SUCCESS_STATE",
                 "matching ACTIVE binding was not committed")
    engine.shutdown(status);
    expect_status("ACTIVATE_SHUTDOWN", status, RDMA_SC_OK);
    expect_unconfigured("ACTIVATE_SHUTDOWN_STATE", engine);
    if (count_host_calls(mem, "release") != 1 ||
        mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error("ACTIVATE_SHUTDOWN_RELEASE",
                 "ACTIVE shutdown did not release backing exactly once")
    engine.shutdown(status);
    expect_status("ACTIVATE_SHUTDOWN_IDEMPOTENT", status, RDMA_SC_OK);
    if (count_host_calls(mem, "release") != 1)
      `uvm_error("ACTIVATE_SHUTDOWN_IDEMPOTENT",
                 "idempotent ACTIVE shutdown released backing again")

    for (int unsigned authority_case = 0; authority_case < 4;
         authority_case++) begin
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("activate_authority_engine_%0d", authority_case)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("activate_authority_mem_%0d", authority_case)
      );
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("activate_authority_scheduler_%0d", authority_case)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("activate_authority_profile_%0d", authority_case)
      );
      prepared_binding = make_binding(
        $sformatf("activate_authority_prepared_%0d", authority_case),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("activate_authority_active_%0d", authority_case),
        RDMA_BIND_ACTIVE
      );
      case (authority_case)
        0: begin
          active_binding.queue_dma.pasid_valid = 1'b0;
          active_binding.queue_dma.pasid = '0;
        end
        1: active_binding.queue_dma.pasid++;
        2: begin
          prepared_binding.queue_dma.dma_domain_valid = 1'b0;
          prepared_binding.queue_dma.dma_domain_id = '0;
        end
        3: active_binding.queue_dma.dma_domain_id++;
      endcase
      cmq = make_cmq(
        $sformatf("activate_authority_cmq_%0d", authority_case),
        prepared_binding
      );
      prepare_defaults(
        $sformatf("ACTIVATE_AUTHORITY_PREPARE_%0d", authority_case),
        engine, mem, prepared_binding, cmq, scheduler, profile,
        runtime_desc
      );
      engine.activate(active_binding, status);
      expect_status(
        $sformatf("ACTIVATE_AUTHORITY_%0d", authority_case), status,
        RDMA_SC_DMA_TRANSLATION
      );
      if (engine.state() != RDMA_CMQ_ENGINE_PREPARED)
        `uvm_error("ACTIVATE_AUTHORITY_ATOMIC",
                   "authority mismatch changed the PREPARED state")
      engine.shutdown(status);
      expect_status(
        $sformatf("ACTIVATE_AUTHORITY_SHUTDOWN_%0d", authority_case),
        status, RDMA_SC_OK
      );
    end
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_prepared_shutdown_lifecycle 中构造或驱动“prepared shutdown lifecycle”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_prepared_shutdown_lifecycle();
    rdma_cmq_engine engine;
    rdma_mock_host_mem first_mem;
    rdma_mock_host_mem second_mem;
    rdma_doorbell_scheduler first_scheduler;
    rdma_doorbell_scheduler second_scheduler;
    rdma_cmq_test_profile first_profile;
    rdma_cmq_test_profile second_profile;
    rdma_function_binding first_binding;
    rdma_function_binding second_binding;
    rdma_function_binding active_binding;
    rdma_cmq first_cmq;
    rdma_cmq second_cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_status status;
    int unsigned first_call_count;

    engine = rdma_cmq_engine::type_id::create("prepared_shutdown_engine");
    first_mem = rdma_mock_host_mem::type_id::create(
      "prepared_shutdown_first_mem"
    );
    first_scheduler = rdma_doorbell_scheduler::type_id::create(
      "prepared_shutdown_first_scheduler"
    );
    first_profile = rdma_cmq_test_profile::type_id::create(
      "prepared_shutdown_first_profile"
    );
    first_binding = make_binding("prepared_shutdown_first_binding",
                                 RDMA_BIND_PREPARED);
    first_cmq = make_cmq("prepared_shutdown_first_cmq", first_binding);
    prepare_defaults("PREPARED_SHUTDOWN_PREPARE", engine, first_mem,
                     first_binding, first_cmq, first_scheduler,
                     first_profile, runtime_desc);

    engine.shutdown(status);
    expect_status("PREPARED_SHUTDOWN", status, RDMA_SC_OK);
    expect_unconfigured("PREPARED_SHUTDOWN_STATE", engine);
    if (count_host_calls(first_mem, "release") != 1 ||
        first_mem.regions.size() != 1 ||
        first_mem.regions[0].mapping == null ||
        first_mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED ||
        engine.published_count() != 0 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0)
      `uvm_error("PREPARED_SHUTDOWN_RELEASE",
                 "PREPARED shutdown did not clear backing and counters")
    first_call_count = first_mem.calls.size();
    engine.shutdown(status);
    expect_status("PREPARED_SHUTDOWN_IDEMPOTENT", status, RDMA_SC_OK);
    if (first_mem.calls.size() != first_call_count ||
        count_host_calls(first_mem, "release") != 1)
      `uvm_error("PREPARED_SHUTDOWN_IDEMPOTENT",
                 "idempotent PREPARED shutdown reused old authority")
    active_binding = make_binding("prepared_shutdown_active_probe",
                                  RDMA_BIND_ACTIVE);
    engine.activate(active_binding, status);
    expect_status("PREPARED_SHUTDOWN_CLEARED_ACTIVATE", status,
                  RDMA_SC_INVALID_STATE);
    if (first_mem.calls.size() != first_call_count)
      `uvm_error("PREPARED_SHUTDOWN_CLEARED_ACTIVATE",
                 "post-shutdown activate reused old host authority")

    second_mem = rdma_mock_host_mem::type_id::create(
      "prepared_shutdown_second_mem"
    );
    second_scheduler = rdma_doorbell_scheduler::type_id::create(
      "prepared_shutdown_second_scheduler"
    );
    second_profile = rdma_cmq_test_profile::type_id::create(
      "prepared_shutdown_second_profile"
    );
    second_binding = make_binding("prepared_shutdown_second_binding",
                                  RDMA_BIND_PREPARED);
    second_binding.function_uid++;
    second_binding.global_function_id++;
    second_binding.generation++;
    second_binding.synchronize_identity_from_legacy_mirrors();
    second_binding.owner_h = second_binding.make_handle();
    second_cmq = make_cmq("prepared_shutdown_second_cmq", second_binding);
    prepare_defaults("PREPARED_SHUTDOWN_REPREPARE", engine, second_mem,
                     second_binding, second_cmq, second_scheduler,
                     second_profile, runtime_desc);
    if (first_mem.calls.size() != first_call_count ||
        first_profile.validation_calls != 1 ||
        second_profile.validation_calls != 1 ||
        engine.published_count() != 0 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0)
      `uvm_error("PREPARED_SHUTDOWN_REPREPARE",
                 "reprepare reused stale collaborators or counters")
    engine.shutdown(status);
    expect_status("PREPARED_SHUTDOWN_REPREPARE_RELEASE", status,
                  RDMA_SC_OK);
    if (count_host_calls(first_mem, "release") != 1 ||
        count_host_calls(second_mem, "release") != 1)
      `uvm_error("PREPARED_SHUTDOWN_REPREPARE_RELEASE",
                 "reprepare released through the wrong collaborator")
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_shutdown_release_retry 中构造或驱动“shutdown release retry”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_shutdown_release_retry();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping retained_snapshot;
    rdma_mock_dma_mapping retained_mock;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "shutdown_retry_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("shutdown_retry_mem");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "shutdown_retry_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "shutdown_retry_profile"
    );
    binding = make_binding("shutdown_retry_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("shutdown_retry_cmq", binding);
    prepare_defaults("SHUTDOWN_RETRY_PREPARE", engine, mem, binding, cmq,
                     scheduler, profile, runtime_desc);
    expect_status("ARM_SHUTDOWN_RELEASE_FAILURE",
                  mem.fail_next("release", rdma_status::make(
                    RDMA_SC_UNKNOWN_HW_ERROR,
                    "injected shutdown release failure"
                  )), RDMA_SC_OK);
    engine.seed_runtime_counters();

    engine.shutdown(status);
    expect_status("SHUTDOWN_RELEASE_FAILURE", status,
                  RDMA_SC_UNKNOWN_HW_ERROR);
    retained_snapshot = engine.mapping_snapshot();
    if (status == null ||
        status.message != "injected shutdown release failure" ||
        engine.state() != RDMA_CMQ_ENGINE_POISONED ||
        retained_snapshot == null ||
        !engine.retry_only_poisoned() ||
        count_host_calls(mem, "release") != 1 ||
        mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("SHUTDOWN_RELEASE_FAILURE",
                 "shutdown release failure lost retained authority")
    if (!$cast(retained_mock, retained_snapshot))
      `uvm_error("SHUTDOWN_RELEASE_FAILURE",
                 "retained shutdown mapping lost allocation identity")

    engine.shutdown(status);
    expect_status("SHUTDOWN_RELEASE_RETRY", status, RDMA_SC_OK);
    expect_unconfigured("SHUTDOWN_RELEASE_RETRY_STATE", engine);
    if (count_host_calls(mem, "release") != 2 ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error("SHUTDOWN_RELEASE_RETRY",
                 "shutdown did not retry and retire the same allocation")
    expect_release_retry_identity("SHUTDOWN_RELEASE_RETRY_IDENTITY", mem,
                                  retained_mock);

    engine.shutdown(status);
    expect_status("SHUTDOWN_RELEASE_RETRY_IDEMPOTENT", status,
                  RDMA_SC_OK);
    if (count_host_calls(mem, "release") != 2)
      `uvm_error("SHUTDOWN_RELEASE_RETRY_IDEMPOTENT",
                 "third shutdown released retired backing again")
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_active_shutdown_release_retry 中构造或驱动“active shutdown release retry”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_active_shutdown_release_retry();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping retained_snapshot;
    rdma_mock_dma_mapping retained_mock;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "active_shutdown_retry_engine"
    );
    mem = rdma_mock_host_mem::type_id::create(
      "active_shutdown_retry_mem"
    );
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "active_shutdown_retry_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "active_shutdown_retry_profile"
    );
    prepared_binding = make_binding("active_shutdown_retry_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("active_shutdown_retry_active",
                                  RDMA_BIND_ACTIVE);
    cmq = make_cmq("active_shutdown_retry_cmq", prepared_binding);
    prepare_defaults("ACTIVE_SHUTDOWN_RETRY_PREPARE", engine, mem,
                     prepared_binding, cmq, scheduler, profile,
                     runtime_desc);
    engine.activate(active_binding, status);
    expect_status("ACTIVE_SHUTDOWN_RETRY_ACTIVATE", status, RDMA_SC_OK);
    expect_status("ARM_ACTIVE_SHUTDOWN_RELEASE_FAILURE",
                  mem.fail_next("release", rdma_status::make(
                    RDMA_SC_UNKNOWN_HW_ERROR,
                    "injected ACTIVE shutdown release failure"
                  )), RDMA_SC_OK);
    engine.seed_runtime_counters();

    engine.shutdown(status);
    expect_status("ACTIVE_SHUTDOWN_RELEASE_FAILURE", status,
                  RDMA_SC_UNKNOWN_HW_ERROR);
    retained_snapshot = engine.mapping_snapshot();
    if (status == null ||
        status.message != "injected ACTIVE shutdown release failure" ||
        !engine.retry_only_poisoned() || retained_snapshot == null ||
        count_host_calls(mem, "release") != 1 ||
        mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("ACTIVE_SHUTDOWN_RELEASE_FAILURE",
                 "ACTIVE release failure did not retain retry-only state")
    if (!$cast(retained_mock, retained_snapshot))
      `uvm_error("ACTIVE_SHUTDOWN_RELEASE_FAILURE",
                 "ACTIVE release failure lost allocation identity")

    engine.shutdown(status);
    expect_status("ACTIVE_SHUTDOWN_RELEASE_RETRY", status, RDMA_SC_OK);
    expect_unconfigured("ACTIVE_SHUTDOWN_RELEASE_RETRY_STATE", engine);
    if (count_host_calls(mem, "release") != 2 ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error("ACTIVE_SHUTDOWN_RELEASE_RETRY",
                 "ACTIVE shutdown retry did not release backing")
    expect_release_retry_identity(
      "ACTIVE_SHUTDOWN_RELEASE_RETRY_IDENTITY", mem, retained_mock
    );
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_null_shutdown_release_retry 中构造或驱动“null shutdown release retry”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_null_shutdown_release_retry();
    rdma_cmq_engine_probe engine;
    rdma_cmq_null_release_once_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping retained_snapshot;
    rdma_mock_dma_mapping retained_mock;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "null_release_retry_engine"
    );
    mem = rdma_cmq_null_release_once_mem::type_id::create(
      "null_release_retry_mem"
    );
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "null_release_retry_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "null_release_retry_profile"
    );
    binding = make_binding("null_release_retry_binding",
                           RDMA_BIND_PREPARED);
    cmq = make_cmq("null_release_retry_cmq", binding);
    prepare_defaults("NULL_RELEASE_RETRY_PREPARE", engine, mem, binding,
                     cmq, scheduler, profile, runtime_desc);
    engine.seed_runtime_counters();

    engine.shutdown(status);
    expect_status("NULL_SHUTDOWN_RELEASE", status, RDMA_SC_INVALID_STATE);
    retained_snapshot = engine.mapping_snapshot();
    if (status == null ||
        status.message != "CMQ shutdown release returned null status" ||
        !engine.retry_only_poisoned() || retained_snapshot == null ||
        count_host_calls(mem, "release") != 1 ||
        mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("NULL_SHUTDOWN_RELEASE",
                 "null release did not retain retry-only authority")
    if (!$cast(retained_mock, retained_snapshot))
      `uvm_error("NULL_SHUTDOWN_RELEASE",
                 "null release lost mapping allocation identity")

    engine.shutdown(status);
    expect_status("NULL_SHUTDOWN_RELEASE_RETRY", status, RDMA_SC_OK);
    expect_unconfigured("NULL_SHUTDOWN_RELEASE_RETRY_STATE", engine);
    if (count_host_calls(mem, "release") != 2 ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error("NULL_SHUTDOWN_RELEASE_RETRY",
                 "null release retry did not release backing")
    expect_release_retry_identity("NULL_SHUTDOWN_RELEASE_RETRY_IDENTITY",
                                  mem, retained_mock);
    engine.shutdown(status);
    expect_status("NULL_SHUTDOWN_RELEASE_IDEMPOTENT", status,
                  RDMA_SC_OK);
    if (count_host_calls(mem, "release") != 2)
      `uvm_error("NULL_SHUTDOWN_RELEASE_IDEMPOTENT",
                 "idempotent shutdown retried a released mapping")
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_missing_host_mem_shutdown 中构造或驱动“missing host mem shutdown”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_missing_host_mem_shutdown();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping retained_snapshot;
    rdma_mock_dma_mapping original_mapping;
    rdma_mock_dma_mapping retained_mapping;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "missing_host_mem_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("missing_host_mem");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "missing_host_mem_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "missing_host_mem_profile"
    );
    binding = make_binding("missing_host_mem_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("missing_host_mem_cmq", binding);
    prepare_defaults("MISSING_HOST_MEM_PREPARE", engine, mem, binding, cmq,
                     scheduler, profile, runtime_desc);
    retained_snapshot = engine.mapping_snapshot();
    if (!$cast(original_mapping, retained_snapshot))
      `uvm_error("MISSING_HOST_MEM_PREPARE",
                 "prepared mapping lost allocation identity")
    engine.seed_runtime_counters();
    engine.drop_host_mem_authority();

    engine.shutdown(status);
    expect_status("MISSING_HOST_MEM_SHUTDOWN", status,
                  RDMA_SC_INVALID_STATE);
    retained_snapshot = engine.mapping_snapshot();
    if (!$cast(retained_mapping, retained_snapshot))
      `uvm_error("MISSING_HOST_MEM_SHUTDOWN",
                 "missing adapter path lost retained mapping")
    if (status == null ||
        status.message != "CMQ shutdown release authority is missing" ||
        !engine.missing_host_mem_poisoned() ||
        count_host_calls(mem, "release") != 0 ||
        mem.regions.size() != 1 || mem.regions[0].mapping == null ||
        mem.regions[0].mapping.state != RDMA_MAPPING_ACTIVE ||
        original_mapping == null || retained_mapping == null ||
        !original_mapping.same_allocation(retained_mapping))
      `uvm_error("MISSING_HOST_MEM_SHUTDOWN",
                 "missing adapter path did not fail closed visibly")

    engine.shutdown(status);
    expect_status("MISSING_HOST_MEM_SHUTDOWN_REPEAT", status,
                  RDMA_SC_INVALID_STATE);
    if (!engine.missing_host_mem_poisoned() ||
        count_host_calls(mem, "release") != 0)
      `uvm_error("MISSING_HOST_MEM_SHUTDOWN_REPEAT",
                 "missing adapter failure was not deterministic")

    engine.restore_host_mem_authority(mem);
    engine.shutdown(status);
    expect_status("MISSING_HOST_MEM_RECOVERY", status, RDMA_SC_OK);
    expect_unconfigured("MISSING_HOST_MEM_RECOVERY_STATE", engine);
    if (count_host_calls(mem, "release") != 1 ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error("MISSING_HOST_MEM_RECOVERY",
                 "restored adapter did not release retained mapping")
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_batch_compaction_and_doorbell 中构造或驱动“batch compaction and doorbell”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_batch_compaction_and_doorbell();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;
    string expected_trace[5] = '{
      "host_write", "host_write", "pcie_dma_barrier",
      "pcie_mmio_barrier", "pcie_mmio_write"
    };

    engine = rdma_cmq_engine_probe::type_id::create("batch_engine");
    mem = rdma_mock_host_mem::type_id::create("batch_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("batch_pcie");
    trace = rdma_mock_call_trace::type_id::create("batch_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create("batch_scheduler");
    profile = rdma_cmq_test_profile::type_id::create("batch_profile");
    prepared_binding = make_binding("batch_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("batch_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("batch_cmq", prepared_binding);
    prepare_active("BATCH", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[3];
    requests[0] = make_command("batch_a", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'ha1);
    requests[1] = make_command(
      "batch_unsupported", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'hb2
    );
    requests[2] = make_command("batch_b", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_B, 8'hc3);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);

    expect_status("BATCH_STATUS", batch_status, RDMA_SC_OK);
    if (tickets.size() != 3 || item_statuses.size() != 3)
      `uvm_error("BATCH_ALIGNMENT", "batch outputs are not input-aligned")
    else begin
      expect_status("BATCH_ITEM_A", item_statuses[0], RDMA_SC_OK);
      expect_status("BATCH_ITEM_UNSUPPORTED", item_statuses[1],
                    RDMA_SC_UNSUPPORTED_OPCODE);
      expect_status("BATCH_ITEM_B", item_statuses[2], RDMA_SC_OK);
      if (tickets[0] == null || tickets[1] != null || tickets[2] == null)
        `uvm_error("BATCH_TICKETS", "batch ticket publication is misaligned")
      else begin
        if (tickets[0].slot_sequence != 0 || tickets[0].sq_index != 0 ||
            tickets[0].sq_wrap || tickets[2].slot_sequence != 1 ||
            tickets[2].sq_index != 1 || tickets[2].sq_wrap)
          `uvm_error("BATCH_COMPACTION",
                     "successful commands did not compact into SQ slots 0/1")
        if (tickets[0].command_id == 0 || tickets[2].command_id == 0 ||
            tickets[0].command_id[4:0] != 0 ||
            tickets[2].command_id[4:0] != 1)
          `uvm_error("BATCH_COMMAND_IDS",
                     "tickets did not use distinct reserved command tokens")
        if (tickets[0].function_h == requests[0].function_h ||
            tickets[0].opcode_key == requests[0].opcode_key ||
            tickets[0].cmq_h == cmq.handle)
          `uvm_error("BATCH_TICKET_DETACH",
                     "published ticket aliases caller-owned input")
      end
    end

    expect_submit_trace("BATCH_TRACE", trace, expected_trace);
    if (mem.calls.size() != 2 ||
        mem.calls[0].method_name != "write" ||
        mem.calls[0].offset != 0 || mem.calls[0].data.size() != 64 ||
        mem.calls[0].data[0] != 8'h10 ||
        mem.calls[0].data[1] != 8'ha1 ||
        mem.calls[0].data[2] != 8'h5e ||
        mem.calls[0].data[4] != 8'h00 ||
        mem.calls[0].data[6] != 8'h00 ||
        mem.calls[1].method_name != "write" ||
        mem.calls[1].offset != 64 || mem.calls[1].data.size() != 64 ||
        mem.calls[1].data[0] != 8'h20 ||
        mem.calls[1].data[1] != 8'hc3 ||
        mem.calls[1].data[2] != 8'h3c ||
        mem.calls[1].data[4] != 8'h01 ||
        mem.calls[1].data[6] != 8'h01)
      `uvm_error("BATCH_SQE_WRITES",
                 "compacted SQE writes or detached bytes are incorrect")
    if (pcie.calls.size() != 3 ||
        pcie.calls[2].method_name != "mmio_write" ||
        pcie.calls[2].function_h == null ||
        !pcie.calls[2].function_h.same_instance(active_binding.make_handle()) ||
        pcie.calls[2].address.value != active_binding.notify_base.value +
                                         64'h80 ||
        pcie.calls[2].data.size() != 8 ||
        pcie.calls[2].data[0] != 8'h02 ||
        pcie.calls[2].data[1] != 8'h00 ||
        pcie.calls[2].data[2] != TEST_CMQ_ID[7:0] ||
        pcie.calls[2].data[3] != TEST_CMQ_ID[15:8])
      `uvm_error("BATCH_DOORBELL",
                 "final CMQ doorbell target or payload is incorrect")
    if (profile.doorbell_calls != 1 || profile.last_final_pi != 2 ||
        profile.last_polarity || profile.last_doorbell_target == null ||
        !profile.last_doorbell_target.same_instance(cmq.handle))
      `uvm_error("BATCH_PROFILE_DOORBELL",
                 "profile did not receive the final compacted PI/identity")
    if (engine.published_count() != 2 ||
        engine.tokens_in_use_count() != 2 ||
        engine.slot_record_count() != 2 ||
        engine.slot_expected_variant(0) != "expected_10_a1" ||
        engine.slot_expected_variant(1) != "expected_20_c3")
      `uvm_error("BATCH_LEDGER", "batch slot ledger was not committed")

    engine.shutdown(status);
    expect_status("BATCH_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_empty_invalid_and_state_rejections 中构造或驱动“empty invalid and state
  //   rejections”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_empty_invalid_and_state_rejections();
    rdma_cmq_engine_probe engine;
    rdma_cmq_engine unconfigured_engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc request;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket ticket;
    rdma_cmq_ticket tickets[];
    rdma_status status;
    rdma_status item_statuses[];
    rdma_status batch_status;

    prepared_binding = make_binding("state_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("state_active", RDMA_BIND_ACTIVE);
    request = make_command("state_request", active_binding,
                           rdma_cmq_test_profile::TEST_OPCODE_A, 8'h11);
    unconfigured_engine = rdma_cmq_engine::type_id::create(
      "unconfigured_submit_engine"
    );
    unconfigured_engine.submit(request, ticket, status);
    expect_status("SUBMIT_UNCONFIGURED", status, RDMA_SC_INVALID_STATE);
    if (ticket != null)
      `uvm_error("SUBMIT_UNCONFIGURED", "inactive engine returned a ticket")
    requests = new[1];
    requests[0] = request;
    unconfigured_engine.submit_batch(requests, tickets, item_statuses,
                                     batch_status);
    expect_status("BATCH_UNCONFIGURED", batch_status,
                  RDMA_SC_INVALID_STATE);
    if (tickets.size() != 1 || item_statuses.size() != 1 ||
        tickets[0] != null)
      `uvm_error("BATCH_UNCONFIGURED", "inactive batch outputs misaligned")

    engine = rdma_cmq_engine_probe::type_id::create("invalid_engine");
    mem = rdma_mock_host_mem::type_id::create("invalid_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("invalid_pcie");
    trace = rdma_mock_call_trace::type_id::create("invalid_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create("invalid_scheduler");
    profile = rdma_cmq_test_profile::type_id::create("invalid_profile");
    cmq = make_cmq("invalid_cmq", prepared_binding);
    expect_status("INVALID_SCHEDULER_CONFIGURE",
                  scheduler.configure(mem, pcie), RDMA_SC_OK);
    engine.prepare(prepared_binding, cmq, 1'b1, 20'h34567, mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("INVALID_PREPARE", status, RDMA_SC_OK);
    clear_submit_observation(mem, pcie, trace);
    engine.submit(request, ticket, status);
    expect_status("SUBMIT_PREPARED", status, RDMA_SC_INVALID_STATE);
    if (ticket != null)
      `uvm_error("SUBMIT_PREPARED", "PREPARED engine returned a ticket")
    expect_no_submit_side_effects("SUBMIT_PREPARED", mem, pcie, trace);

    requests = new[0];
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("EMPTY_PREPARED", batch_status, RDMA_SC_INVALID_STATE);
    if (tickets.size() != 0 || item_statuses.size() != 0)
      `uvm_error("EMPTY_PREPARED", "empty inactive outputs are not empty")
    expect_no_submit_side_effects("EMPTY_PREPARED", mem, pcie, trace);

    engine.activate(active_binding, status);
    expect_status("INVALID_ACTIVATE", status, RDMA_SC_OK);
    requests = new[0];
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("EMPTY_ACTIVE", batch_status, RDMA_SC_OK);
    if (tickets.size() != 0 || item_statuses.size() != 0)
      `uvm_error("EMPTY_ACTIVE", "empty batch outputs are not empty")
    expect_no_submit_side_effects("EMPTY_ACTIVE", mem, pcie, trace);

    requests = new[3];
    requests[0] = null;
    requests[1] = make_command("invalid_body", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h22);
    requests[1].body = null;
    requests[2] = make_command(
      "invalid_unsupported", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'h33
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("ALL_INVALID_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 3 || item_statuses.size() != 3)
      `uvm_error("ALL_INVALID_ALIGNMENT", "invalid outputs misaligned")
    else begin
      expect_status("ALL_INVALID_NULL", item_statuses[0],
                    RDMA_SC_INVALID_ARGUMENT);
      expect_status("ALL_INVALID_BODY", item_statuses[1],
                    RDMA_SC_INVALID_ARGUMENT);
      expect_status("ALL_INVALID_OPCODE", item_statuses[2],
                    RDMA_SC_UNSUPPORTED_OPCODE);
      foreach (tickets[i])
        if (tickets[i] != null)
          `uvm_error("ALL_INVALID_TICKET", "invalid item returned a ticket")
    end
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0)
      `uvm_error("ALL_INVALID_LEDGER", "invalid batch changed the ledger")
    expect_no_submit_side_effects("ALL_INVALID_EFFECTS", mem, pcie, trace);

    engine.shutdown(status);
    expect_status("INVALID_SHUTDOWN", status, RDMA_SC_OK);
  endtask


  // 功能：在测试辅助 rdma_cmq_engine_test.check_poll_empty_ledger_and_partial_drain 中构造或驱动“poll empty ledger and partial
  //   drain”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_poll_empty_ledger_and_partial_drain();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc request;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket ticket;
    rdma_cmq_ticket tickets[];
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_cqes[2];
    rdma_status status;
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status injected;

    engine = rdma_cmq_engine_probe::type_id::create(
      "poll_empty_ledger_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("poll_empty_ledger_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("poll_empty_ledger_pcie");
    trace = rdma_mock_call_trace::type_id::create(
      "poll_empty_ledger_trace"
    );
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "poll_empty_ledger_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "poll_empty_ledger_profile"
    );
    prepared_binding = make_binding(
      "poll_empty_ledger_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "poll_empty_ledger_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("poll_empty_ledger_cmq", prepared_binding);
    expect_status(
      "POLL_EMPTY_LEDGER_SCHEDULER_CONFIGURE",
      scheduler.configure(mem, pcie), RDMA_SC_OK
    );
    engine.prepare(
      prepared_binding, cmq, 1'b1, 20'h34567, mem, scheduler, profile,
      runtime_desc, status
    );
    expect_status("POLL_EMPTY_LEDGER_PREPARE", status, RDMA_SC_OK);
    engine.activate(active_binding, status);
    expect_status("POLL_EMPTY_LEDGER_ACTIVATE", status, RDMA_SC_OK);
    clear_submit_observation(mem, pcie, trace);
    mapping = engine.mapping_snapshot();
    expect_empty_poll_without_read("POLL_EMPTY_AFTER_ACTIVATE", engine, mem);
    begin
      rdma_cmq_completion queued_completion;

      queued_completion = rdma_cmq_completion::type_id::create(
        "poll_empty_queued_completion"
      );
      engine.seed_terminal_completion(queued_completion);
      mem.calls.delete();
      engine.poll(completions, diagnostics, status);
      expect_status("POLL_EMPTY_DRAIN_FIFO_STATUS", status, RDMA_SC_OK);
      if (completions.size() != 1 ||
          completions[0] != queued_completion || diagnostics.size() != 0 ||
          mem.calls.size() != 0 ||
          engine.state() != RDMA_CMQ_ENGINE_ACTIVE ||
          engine.published_count() != 0 || engine.retired_count() != 0 ||
          engine.cq_consumed_count() != 0 ||
          engine.terminal_fifo_count() != 0)
        `uvm_error(
          "POLL_EMPTY_DRAIN_FIFO",
          "empty hardware ledger did not drain the terminal FIFO"
        )
    end
    requests = new[0];
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("EMPTY_ACTIVE", batch_status, RDMA_SC_OK);
    if (tickets.size() != 0 || item_statuses.size() != 0)
      `uvm_error("EMPTY_ACTIVE", "empty batch outputs are not empty")
    expect_no_submit_side_effects("EMPTY_ACTIVE", mem, pcie, trace);

    requests = new[4];
    requests[0] = null;
    requests[1] = make_command("invalid_body", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h22);
    requests[1].body = null;
    requests[2] = make_command(
      "invalid_unsupported", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'h33
    );
    requests[3] = make_command(
      "invalid_codec", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'h44
    );
    profile.fail_compose_opcode = rdma_cmq_test_profile::TEST_OPCODE_B;
    profile.compose_failure_code = RDMA_SC_CODEC_ERROR;
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("ALL_INVALID_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 4 || item_statuses.size() != 4)
      `uvm_error("ALL_INVALID_ALIGNMENT", "invalid outputs misaligned")
    else begin
      expect_status("ALL_INVALID_NULL", item_statuses[0],
                    RDMA_SC_INVALID_ARGUMENT);
      expect_status("ALL_INVALID_BODY", item_statuses[1],
                    RDMA_SC_INVALID_ARGUMENT);
      expect_status("ALL_INVALID_OPCODE", item_statuses[2],
                    RDMA_SC_UNSUPPORTED_OPCODE);
      expect_status("ALL_INVALID_CODEC", item_statuses[3],
                    RDMA_SC_CODEC_ERROR);
      foreach (tickets[i])
        if (tickets[i] != null)
          `uvm_error("ALL_INVALID_TICKET", "invalid item returned a ticket")
    end
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0)
      `uvm_error("ALL_INVALID_LEDGER", "invalid batch changed the ledger")
    expect_no_submit_side_effects("ALL_INVALID_EFFECTS", mem, pcie, trace);
    profile.fail_compose_opcode = '0;
    expect_empty_poll_without_read("POLL_EMPTY_AFTER_ALL_FAIL", engine, mem);

    injected = rdma_status::make(
      RDMA_SC_TIMEOUT, "injected empty-ledger transport failure"
    );
    expect_status(
      "POLL_EMPTY_ARM_TRANSPORT",
      pcie.fail_next("dma_visibility_barrier", injected), RDMA_SC_OK
    );
    request = make_command(
      "poll_empty_transport_failure", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h45, 10us
    );
    engine.submit(request, ticket, status);
    expect_status("POLL_EMPTY_TRANSPORT_SUBMIT", status, RDMA_SC_TIMEOUT);
    if (ticket != null)
      `uvm_error(
        "POLL_EMPTY_TRANSPORT_TICKET",
        "transport-failed submission returned a ticket"
      )
    expect_empty_poll_without_read(
      "POLL_EMPTY_AFTER_TRANSPORT_FAIL", engine, mem
    );

    requests = new[2];
    requests[0] = make_command(
      "poll_partial_drain_request_0", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h46, 10us
    );
    requests[1] = make_command(
      "poll_partial_drain_request_1", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'h47, 10us
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("POLL_PARTIAL_DRAIN_SUBMIT", batch_status, RDMA_SC_OK);
    if (tickets.size() != 2 || tickets[0] == null || tickets[1] == null)
      `uvm_error(
        "POLL_PARTIAL_DRAIN_TICKETS",
        "partial-drain submission did not return two tickets"
      )
    else begin
      write_profile_cqe(
        "POLL_PARTIAL_DRAIN_CQE_0", mem, mapping, profile, 0, 1'b1,
        tickets[0], 0, raw_cqes[0]
      );
      write_profile_cqe(
        "POLL_PARTIAL_DRAIN_CQE_1", mem, mapping, profile, 1, 1'b1,
        tickets[1], 0, raw_cqes[1]
      );
    end
    profile.inspect_failure_call = profile.inspect_calls + 2;
    // A transient inspection failure remains retryable.  Codec failures are
    // malformed hardware evidence and intentionally poison the engine.
    profile.inspect_failure_code = RDMA_SC_TIMEOUT;
    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_PARTIAL_DRAIN_STATUS", status, RDMA_SC_TIMEOUT);
    if (completions.size() != 1 || diagnostics.size() != 0 ||
        completions[0] == null || completions[0].ticket == null ||
        completions[0].ticket.command_id != tickets[0].command_id ||
        engine.published_count() != 2 ||
        engine.cq_consumed_count() != 1 || engine.retired_count() != 1 ||
        engine.tokens_in_use_count() != 1 ||
        engine.slot_record_count() != 1 ||
        engine.command_registry_count() != 1 ||
        engine.entry_registry_count() != 1 ||
        engine.terminal_fifo_count() != 0)
      `uvm_error(
        "POLL_PARTIAL_DRAIN_ATOMIC",
        "partial drain lost its first output or changed the second command"
      )
    expect_poll_read_geometry("POLL_PARTIAL_DRAIN_READ", mem, 0, 2);

    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_PARTIAL_DRAIN_RETRY_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0 ||
        completions[0] == null || completions[0].ticket == null ||
        completions[0].ticket.command_id != tickets[1].command_id ||
        engine.published_count() != 2 ||
        engine.cq_consumed_count() != 2 || engine.retired_count() != 2 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0 ||
        engine.terminal_fifo_count() != 0)
      `uvm_error(
        "POLL_PARTIAL_DRAIN_RETRY",
        "partial-drain retry did not finish the retained command"
      )
    expect_poll_read_geometry("POLL_PARTIAL_DRAIN_RETRY_READ", mem, 1, 1);
    expect_empty_poll_with_read("POLL_EMPTY_AFTER_DRAIN", engine, mem);

    // CQ backing persists independently of the software ledger.  Once the
    // ring is fully retired, an owner-ready stale CQE at the current consumer
    // slot must be diagnosed before a later command can reuse its identity.
    write_profile_cqe(
      "POLL_EMPTY_STALE_CQE", mem, mapping, profile, 2, 1'b1,
      tickets[1], 0, raw_cqes[0]
    );
    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_EMPTY_STALE_STATUS", status, RDMA_SC_CODEC_ERROR);
    if (completions.size() != 0 || diagnostics.size() != 1 ||
        engine.state() != RDMA_CMQ_ENGINE_POISONED ||
        engine.published_count() != 2 || engine.retired_count() != 2 ||
        engine.cq_consumed_count() != 2 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error("POLL_EMPTY_STALE",
                 "owner-ready stale CQE was ignored or changed authority")
    if (diagnostics.size() == 1)
      expect_poison_diagnostic(
        "POLL_EMPTY_STALE_DIAGNOSTIC", engine, diagnostics[0],
        RDMA_CMQ_DIAG_UNKNOWN_CQE, null, raw_cqes[0], active_binding, cmq
      );
    expect_poll_read_geometry("POLL_EMPTY_STALE_READ", mem, 2, 1);

    request = make_command(
      "poll_empty_stale_rejected", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h48, 10us
    );
    engine.submit(request, ticket, status);
    expect_status("POLL_EMPTY_STALE_LATER_SUBMIT", status,
                  RDMA_SC_INVALID_STATE);
    if (ticket != null)
      `uvm_error("POLL_EMPTY_STALE_LATER_SUBMIT",
                 "poisoned stale-CQE engine returned a later ticket")

    engine.shutdown(status);
    expect_status("INVALID_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_pre_read_poll_ledger_fail_closed 中构造或驱动“pre read poll ledger fail
  //   closed”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_pre_read_poll_ledger_fail_closed();
    string fault_labels[4];

    fault_labels[0] = "COUNTER";
    fault_labels[1] = "SLOT";
    fault_labels[2] = "TOKEN";
    fault_labels[3] = "REGISTRY";
    for (int unsigned fault = 0; fault < 4; fault++) begin
      rdma_cmq_engine_probe engine;
      rdma_mock_host_mem mem;
      rdma_cmq_test_pcie pcie;
      rdma_doorbell_scheduler scheduler;
      rdma_cmq_test_profile profile;
      rdma_function_binding prepared_binding;
      rdma_function_binding active_binding;
      rdma_cmq cmq;
      rdma_cmq_runtime_desc runtime_desc;
      rdma_cmq_command_desc request;
      rdma_cmq_ticket ticket;
      rdma_cmq_completion completions[$];
      rdma_cmq_diagnostic diagnostics[$];
      rdma_status status;
      string label;

      label = {"POLL_PRE_READ_LEDGER_", fault_labels[fault]};
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("pre_read_ledger_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("pre_read_ledger_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("pre_read_ledger_pcie_%0d", fault)
      );
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("pre_read_ledger_scheduler_%0d", fault)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("pre_read_ledger_profile_%0d", fault)
      );
      prepared_binding = make_binding(
        $sformatf("pre_read_ledger_prepared_%0d", fault),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("pre_read_ledger_active_%0d", fault), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq(
        $sformatf("pre_read_ledger_cmq_%0d", fault), prepared_binding
      );
      prepare_active(
        label, engine, mem, pcie, scheduler, profile, prepared_binding,
        active_binding, cmq, runtime_desc
      );

      engine.tamper_empty_ledger(
        rdma_cmq_test_empty_ledger_fault_e'(fault)
      );
      expect_inconsistent_empty_poll_without_read(label, engine, mem);

      request = make_command(
        $sformatf("pre_read_ledger_rejected_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'h70 + fault), 10us
      );
      engine.submit(request, ticket, status);
      expect_status({label, "_LATER_SUBMIT"}, status,
                    RDMA_SC_INVALID_STATE);
      if (ticket != null)
        `uvm_error(label, "pre-read poison returned a later ticket")
      engine.poll(completions, diagnostics, status);
      expect_status({label, "_LATER_POLL"}, status, RDMA_SC_INVALID_STATE);
      if (completions.size() != 0 || diagnostics.size() != 0)
        `uvm_error(label, "pre-read poison returned later poll output")
      engine.expire(completions, status);
      expect_status({label, "_LATER_EXPIRE"}, status,
                    RDMA_SC_INVALID_STATE);
      if (completions.size() != 0)
        `uvm_error(label, "pre-read poison returned later expiry output")

      engine.shutdown(status);
      expect_status({label, "_SHUTDOWN"}, status, RDMA_SC_OK);
    end
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_submit_wrapper_and_snapshot_detachment 中构造或驱动“submit wrapper and snapshot
  //   detachment”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_submit_wrapper_and_snapshot_detachment();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_blocking_pcie blocking_pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc request;
    rdma_cmq_sqe_model body;
    rdma_cmq_ticket ticket;
    rdma_status status;
    bit submit_done;
    longint unsigned internal_command_id;
    string expected_trace[4] = '{
      "host_write", "pcie_dma_barrier", "pcie_mmio_barrier",
      "pcie_mmio_write"
    };

    engine = rdma_cmq_engine_probe::type_id::create("wrapper_engine");
    mem = rdma_mock_host_mem::type_id::create("wrapper_mem");
    blocking_pcie = rdma_cmq_test_blocking_pcie::type_id::create(
      "wrapper_pcie"
    );
    trace = rdma_mock_call_trace::type_id::create("wrapper_trace");
    mem.set_call_trace(trace);
    blocking_pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "wrapper_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("wrapper_profile");
    prepared_binding = make_binding("wrapper_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("wrapper_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("wrapper_cmq", prepared_binding);
    prepare_active("WRAPPER", engine, mem, blocking_pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, blocking_pcie, trace);

    request = make_command(
      "wrapper_unsupported", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'h33
    );
    engine.submit(request, ticket, status);
    expect_status("WRAPPER_UNSUPPORTED", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);
    if (ticket != null)
      `uvm_error("WRAPPER_UNSUPPORTED", "failed wrapper returned a ticket")
    expect_no_submit_side_effects("WRAPPER_UNSUPPORTED", mem,
                                  blocking_pcie, trace);

    request = make_command("wrapper_snapshot", active_binding,
                           rdma_cmq_test_profile::TEST_OPCODE_A, 8'h44,
                           10us);
    if (!$cast(body, request.body))
      `uvm_fatal("WRAPPER_SETUP", "snapshot body type is invalid")
    blocking_pcie.block_dma_barrier = 1'b1;
    blocking_pcie.release_dma_barrier = 1'b0;
    submit_done = 1'b0;
    ticket = null;
    status = null;
    fork
      begin
        engine.submit(request, ticket, status);
        submit_done = 1'b1;
      end
    join_none
    wait (blocking_pcie.dma_barrier_entered);
    if (submit_done || ticket != null || engine.published_count() != 0)
      `uvm_error("WRAPPER_PUBLICATION_GATE",
                 "wrapper published before the scheduler transaction")

    request.opcode_key.opcode = rdma_cmq_test_profile::TEST_OPCODE_B;
    request.opcode_key.variant = "caller_mutated";
    request.function_h.function_uid++;
    request.function_h.object_id++;
    request.function_h.generation++;
    body.flags = 8'h99;
    body.command_id = 64'h99;
    request.qpc_signature_source.bytes[0] = 8'h88;
    profile.last_expected_alias.variant = "profile_alias_mutated";
    blocking_pcie.release_dma_barrier = 1'b1;
    wait (submit_done);

    expect_status("WRAPPER_SNAPSHOT", status, RDMA_SC_OK);
    if (ticket == null)
      `uvm_error("WRAPPER_SNAPSHOT", "successful wrapper returned no ticket")
    else begin
      if (ticket.opcode_key.opcode !=
            rdma_cmq_test_profile::TEST_OPCODE_A ||
          ticket.opcode_key.variant != "variant_10" ||
          ticket.function_h.function_uid != TEST_FUNCTION_UID ||
          ticket.function_h.object_id != TEST_FUNCTION_ID ||
          ticket.function_h.generation != TEST_GENERATION)
        `uvm_error("WRAPPER_SNAPSHOT_TICKET",
                   "ticket was derived from caller-mutated input")
      if (engine.slot_ticket_command_id(0) != ticket.command_id)
        `uvm_error("WRAPPER_SNAPSHOT_TICKET",
                   "slot record does not own a detached ticket value")
      internal_command_id = engine.slot_ticket_command_id(0);
      ticket.command_id = 0;
      ticket.opcode_key.variant = "caller_mutated_ticket";
      if (engine.slot_ticket_command_id(0) != internal_command_id ||
          engine.slot_expected_variant(0) != "expected_10_44")
        `uvm_error("WRAPPER_OUTPUT_TICKET_DETACH",
                   "caller ticket mutation changed slot authority")
    end
    if (mem.calls.size() != 1 || mem.calls[0].offset != 0 ||
        mem.calls[0].data.size() != 64 ||
        mem.calls[0].data[0] != 8'h10 ||
        mem.calls[0].data[1] != 8'h44 ||
        mem.calls[0].data[2] != 8'hbb ||
        mem.calls[0].data[3] != TEST_FUNCTION_ID[7:0])
      `uvm_error("WRAPPER_SNAPSHOT_SQE",
                 "written SQE was derived from caller-mutated input")
    if (engine.slot_expected_variant(0) != "expected_10_44")
      `uvm_error("WRAPPER_SNAPSHOT_EXPECTED",
                 "slot expected response aliases profile-owned output")
    expect_submit_trace("WRAPPER_SNAPSHOT_TRACE", trace, expected_trace);
    if (blocking_pcie.calls.size() != 3)
      `uvm_error("WRAPPER_ONE_DOORBELL",
                 "one-item wrapper did not schedule exactly one doorbell")

    engine.shutdown(status);
    expect_status("WRAPPER_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_nested_command_snapshot_failures 中构造或驱动“nested command snapshot
  //   failures”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_nested_command_snapshot_failures();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_clone_fault_function_handle fault_function;
    rdma_cmq_clone_fault_handle fault_handle;
    rdma_cmq_clone_fault_opcode_key fault_opcode;
    rdma_cmq_clone_fault_body fault_body;
    rdma_cmq_clone_fault_image fault_image;
    rdma_cmq_sqe_model source_body;
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("nested_clone_engine");
    mem = rdma_mock_host_mem::type_id::create("nested_clone_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("nested_clone_pcie");
    trace = rdma_mock_call_trace::type_id::create("nested_clone_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "nested_clone_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "nested_clone_profile"
    );
    prepared_binding = make_binding("nested_clone_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("nested_clone_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("nested_clone_cmq", prepared_binding);
    prepare_active("NESTED_CLONE", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[18];
    foreach (requests[i])
      requests[i] = make_command(
        $sformatf("nested_clone_%0d", i), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'h70 + i)
      );

    fault_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "nested_function_null"
      );
    fault_function.copy(requests[0].function_h);
    fault_function.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    requests[0].function_h = fault_function;
    fault_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "nested_function_self"
      );
    fault_function.copy(requests[1].function_h);
    fault_function.clone_fault = RDMA_CMQ_TEST_CLONE_SELF;
    requests[1].function_h = fault_function;

    fault_opcode = rdma_cmq_clone_fault_opcode_key::type_id::create(
      "nested_opcode_null"
    );
    fault_opcode.copy(requests[2].opcode_key);
    fault_opcode.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    requests[2].opcode_key = fault_opcode;
    fault_opcode = rdma_cmq_clone_fault_opcode_key::type_id::create(
      "nested_opcode_self"
    );
    fault_opcode.copy(requests[3].opcode_key);
    fault_opcode.clone_fault = RDMA_CMQ_TEST_CLONE_SELF;
    requests[3].opcode_key = fault_opcode;

    if (!$cast(source_body, requests[4].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_body = rdma_cmq_clone_fault_body::type_id::create(
      "nested_body_null"
    );
    fault_body.copy(source_body);
    fault_body.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    requests[4].body = fault_body;
    if (!$cast(source_body, requests[5].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_body = rdma_cmq_clone_fault_body::type_id::create(
      "nested_body_self"
    );
    fault_body.copy(source_body);
    fault_body.clone_fault = RDMA_CMQ_TEST_CLONE_SELF;
    requests[5].body = fault_body;

    fault_image = rdma_cmq_clone_fault_image::type_id::create(
      "nested_signature_null"
    );
    fault_image.copy(requests[6].qpc_signature_source);
    fault_image.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    requests[6].qpc_signature_source = fault_image;
    fault_image = rdma_cmq_clone_fault_image::type_id::create(
      "nested_signature_self"
    );
    fault_image.copy(requests[7].qpc_signature_source);
    fault_image.clone_fault = RDMA_CMQ_TEST_CLONE_SELF;
    requests[7].qpc_signature_source = fault_image;

    if (!$cast(source_body, requests[8].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "nested_body_function_null"
      );
    fault_function.copy(source_body.function_h);
    fault_function.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    source_body.function_h = fault_function;
    if (!$cast(source_body, requests[9].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "nested_body_function_wrong"
      );
    fault_function.copy(source_body.function_h);
    fault_function.clone_fault = RDMA_CMQ_TEST_CLONE_WRONG_TYPE;
    source_body.function_h = fault_function;
    if (!$cast(source_body, requests[10].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "nested_body_function_self"
      );
    fault_function.copy(source_body.function_h);
    fault_function.clone_fault = RDMA_CMQ_TEST_CLONE_SELF;
    source_body.function_h = fault_function;

    if (!$cast(source_body, requests[11].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_handle = rdma_cmq_clone_fault_handle::type_id::create(
      "nested_body_target_null"
    );
    fault_handle.copy(source_body.target_h);
    fault_handle.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    source_body.target_h = fault_handle;
    if (!$cast(source_body, requests[12].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_handle = rdma_cmq_clone_fault_handle::type_id::create(
      "nested_body_target_wrong"
    );
    fault_handle.copy(source_body.target_h);
    fault_handle.clone_fault = RDMA_CMQ_TEST_CLONE_WRONG_TYPE;
    source_body.target_h = fault_handle;
    if (!$cast(source_body, requests[13].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_handle = rdma_cmq_clone_fault_handle::type_id::create(
      "nested_body_target_self"
    );
    fault_handle.copy(source_body.target_h);
    fault_handle.clone_fault = RDMA_CMQ_TEST_CLONE_SELF;
    source_body.target_h = fault_handle;

    if (!$cast(source_body, requests[14].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_body = rdma_cmq_clone_fault_body::type_id::create(
      "nested_body_context_null"
    );
    fault_body.copy(source_body);
    fault_body.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    source_body.context_model = fault_body;
    if (!$cast(source_body, requests[15].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_body = rdma_cmq_clone_fault_body::type_id::create(
      "nested_body_context_wrong"
    );
    fault_body.copy(source_body);
    fault_body.clone_fault = RDMA_CMQ_TEST_CLONE_WRONG_TYPE;
    source_body.context_model = fault_body;
    if (!$cast(source_body, requests[16].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_body = rdma_cmq_clone_fault_body::type_id::create(
      "nested_body_context_self"
    );
    fault_body.copy(source_body);
    fault_body.clone_fault = RDMA_CMQ_TEST_CLONE_SELF;
    source_body.context_model = fault_body;

    if (!$cast(source_body, requests[17].body))
      `uvm_fatal("NESTED_CLONE_SETUP", "source body type is invalid")
    fault_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "nested_body_function_sibling_alias"
      );
    fault_function.copy(source_body.function_h);
    fault_function.clone_fault = RDMA_CMQ_TEST_CLONE_GOOD;
    source_body.target_h = fault_function;
    fault_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "nested_body_function_alias_source"
      );
    fault_function.copy(source_body.function_h);
    fault_function.clone_fault = RDMA_CMQ_TEST_CLONE_ALIAS;
    fault_function.alias_once = 1'b1;
    if (!$cast(fault_function.alias_target, source_body.target_h))
      `uvm_fatal("NESTED_CLONE_SETUP", "alias target type is invalid")
    source_body.function_h = fault_function;

    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("NESTED_CLONE_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != requests.size() ||
        item_statuses.size() != requests.size())
      `uvm_error("NESTED_CLONE_ALIGNMENT",
                 "nested-clone outputs are misaligned")
    else begin
      foreach (requests[i]) begin
        expect_status($sformatf("NESTED_CLONE_ITEM_%0d", i),
                      item_statuses[i], RDMA_SC_INVALID_ARGUMENT);
        if (tickets[i] != null)
          `uvm_error("NESTED_CLONE_TICKET",
                     $sformatf("nested-clone item %0d returned ticket", i))
      end
    end
    expect_no_submit_side_effects("NESTED_CLONE_EFFECTS", mem, pcie,
                                  trace);
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0)
      `uvm_error("NESTED_CLONE_LEDGER",
                 "nested clone failure changed the authority ledger")

    engine.shutdown(status);
    expect_status("NESTED_CLONE_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_mutating_clone_source_restoration 中构造或驱动“mutating clone source
  //   restoration”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_mutating_clone_source_restoration();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_function_handle saved_function_refs[];
    rdma_cmq_opcode_key saved_opcode_refs[];
    rdma_hw_model saved_body_refs[];
    rdma_hw_image saved_signature_refs[];
    rdma_function_handle saved_function_values[];
    rdma_cmq_opcode_key saved_opcode_values[];
    rdma_hw_image saved_signature_values[];
    rdma_function_handle saved_body_function_refs[];
    rdma_handle saved_body_target_refs[];
    rdma_hw_model saved_body_context_refs[];
    string saved_body_values[];
    bit saved_vfid_override[];
    bit [10:0] saved_use_vfid[];
    time saved_timeout[];
    rdma_cmq_sqe_model source_body;
    rdma_cmq_clone_fault_function_handle fault_function;
    rdma_cmq_clone_fault_opcode_key fault_opcode;
    rdma_cmq_clone_fault_image fault_image;
    rdma_cmq_clone_fault_body fault_body;
    rdma_cmq_clone_fault_qpc fault_qpc;
    rdma_cmq_clone_fault_handle fault_handle;
    rdma_cmq_clone_fault_ring fault_ring;
    rdma_qpc_model qpc;
    rdma_qpc_model outer_qpc;
    rdma_qpc_model nested_qpc;
    rdma_cqc_model nested_cqc;
    rdma_handle saved_outer_qp_h;
    rdma_handle saved_outer_pd_h;
    rdma_handle saved_outer_send_cq_h;
    rdma_handle saved_outer_recv_cq_h;
    rdma_handle saved_outer_srq_h;
    rdma_handle saved_nested_qp_h;
    rdma_handle saved_nested_pd_h;
    rdma_handle saved_nested_send_cq_h;
    rdma_handle saved_nested_recv_cq_h;
    rdma_handle saved_nested_srq_h;
    rdma_handle saved_cqc_cq_h;
    rdma_handle saved_cqc_ceq_h;
    rdma_page_table_layout saved_cqc_page_layout;
    rdma_ring_position saved_cqc_producer;
    rdma_ring_position saved_cqc_consumer;
    int unsigned saved_outer_host_id;
    int unsigned saved_nested_object_id;
    int unsigned saved_cqc_producer_index;
    int unsigned saved_outer_flags;
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "mutating_source_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("mutating_source_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("mutating_source_pcie");
    trace = rdma_mock_call_trace::type_id::create("mutating_source_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "mutating_source_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "mutating_source_profile"
    );
    prepared_binding = make_binding("mutating_source_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("mutating_source_active",
                                  RDMA_BIND_ACTIVE);
    cmq = make_cmq("mutating_source_cmq", prepared_binding);
    prepare_active("MUTATING_SOURCE", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[7];
    foreach (requests[i])
      requests[i] = make_command(
        $sformatf("mutating_source_%0d", i), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hc0 + i)
      );

    fault_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "mutating_source_function"
      );
    fault_function.copy(requests[0].function_h);
    fault_function.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    requests[0].function_h = fault_function;

    fault_opcode = rdma_cmq_clone_fault_opcode_key::type_id::create(
      "mutating_source_opcode"
    );
    fault_opcode.copy(requests[1].opcode_key);
    fault_opcode.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    requests[1].opcode_key = fault_opcode;

    fault_image = rdma_cmq_clone_fault_image::type_id::create(
      "mutating_source_image"
    );
    fault_image.copy(requests[2].qpc_signature_source);
    fault_image.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    requests[2].qpc_signature_source = fault_image;

    if (!$cast(source_body, requests[3].body))
      `uvm_fatal("MUTATING_SOURCE_SETUP", "SQE source body is invalid")
    fault_body = rdma_cmq_clone_fault_body::type_id::create(
      "mutating_source_sqe"
    );
    fault_body.copy(source_body);
    fault_body.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    requests[3].body = fault_body;
    saved_outer_flags = fault_body.flags;

    if (!$cast(source_body, requests[4].body))
      `uvm_fatal("MUTATING_SOURCE_SETUP", "QPC outer body is invalid")
    qpc = make_qpc_context("mutating_source_outer_qpc", active_binding);
    fault_qpc = rdma_cmq_clone_fault_qpc::type_id::create(
      "mutating_source_qpc"
    );
    fault_qpc.copy(qpc);
    fault_qpc.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    source_body.context_model = fault_qpc;
    outer_qpc = fault_qpc;
    saved_outer_host_id = outer_qpc.host_id;
    saved_outer_qp_h = outer_qpc.qp_h;
    saved_outer_pd_h = outer_qpc.pd_h;
    saved_outer_send_cq_h = outer_qpc.send_cq_h;
    saved_outer_recv_cq_h = outer_qpc.recv_cq_h;
    saved_outer_srq_h = outer_qpc.srq_h;

    if (!$cast(source_body, requests[5].body))
      `uvm_fatal("MUTATING_SOURCE_SETUP", "QPC nested body is invalid")
    nested_qpc = make_qpc_context("mutating_source_nested_qpc",
                                  active_binding);
    fault_handle = rdma_cmq_clone_fault_handle::type_id::create(
      "mutating_source_qpc_handle"
    );
    fault_handle.copy(nested_qpc.qp_h);
    fault_handle.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    nested_qpc.qp_h = fault_handle;
    source_body.context_model = nested_qpc;
    saved_nested_object_id = fault_handle.object_id;
    saved_nested_qp_h = nested_qpc.qp_h;
    saved_nested_pd_h = nested_qpc.pd_h;
    saved_nested_send_cq_h = nested_qpc.send_cq_h;
    saved_nested_recv_cq_h = nested_qpc.recv_cq_h;
    saved_nested_srq_h = nested_qpc.srq_h;

    if (!$cast(source_body, requests[6].body))
      `uvm_fatal("MUTATING_SOURCE_SETUP", "CQC nested body is invalid")
    nested_cqc = make_cqc_context("mutating_source_nested_cqc",
                                  active_binding);
    fault_ring = rdma_cmq_clone_fault_ring::type_id::create(
      "mutating_source_cqc_ring"
    );
    fault_ring.copy(nested_cqc.producer);
    fault_ring.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    nested_cqc.producer = fault_ring;
    source_body.context_model = nested_cqc;
    saved_cqc_producer_index = fault_ring.index;
    saved_cqc_cq_h = nested_cqc.cq_h;
    saved_cqc_ceq_h = nested_cqc.ceq_h;
    saved_cqc_page_layout = nested_cqc.page_layout;
    saved_cqc_producer = nested_cqc.producer;
    saved_cqc_consumer = nested_cqc.consumer;

    saved_function_refs = new[requests.size()];
    saved_opcode_refs = new[requests.size()];
    saved_body_refs = new[requests.size()];
    saved_signature_refs = new[requests.size()];
    saved_function_values = new[requests.size()];
    saved_opcode_values = new[requests.size()];
    saved_signature_values = new[requests.size()];
    saved_body_function_refs = new[requests.size()];
    saved_body_target_refs = new[requests.size()];
    saved_body_context_refs = new[requests.size()];
    saved_body_values = new[requests.size()];
    saved_vfid_override = new[requests.size()];
    saved_use_vfid = new[requests.size()];
    saved_timeout = new[requests.size()];
    foreach (requests[i]) begin
      saved_function_refs[i] = requests[i].function_h;
      saved_opcode_refs[i] = requests[i].opcode_key;
      saved_body_refs[i] = requests[i].body;
      saved_signature_refs[i] = requests[i].qpc_signature_source;
      saved_vfid_override[i] = requests[i].vfid_override;
      saved_use_vfid[i] = requests[i].use_vfid;
      saved_timeout[i] = requests[i].timeout;
      saved_function_values[i] = rdma_function_handle::type_id::create(
        $sformatf("mutating_source_saved_function_%0d", i)
      );
      saved_function_values[i].copy(requests[i].function_h);
      saved_opcode_values[i] = rdma_cmq_opcode_key::type_id::create(
        $sformatf("mutating_source_saved_opcode_%0d", i)
      );
      saved_opcode_values[i].copy(requests[i].opcode_key);
      saved_signature_values[i] = rdma_hw_image::type_id::create(
        $sformatf("mutating_source_saved_signature_%0d", i)
      );
      saved_signature_values[i].copy(requests[i].qpc_signature_source);
      if (!$cast(source_body, requests[i].body))
        `uvm_fatal("MUTATING_SOURCE_SETUP", "saved SQE body is invalid")
      saved_body_function_refs[i] = source_body.function_h;
      saved_body_target_refs[i] = source_body.target_h;
      saved_body_context_refs[i] = source_body.context_model;
      saved_body_values[i] = engine.probe_body_value_key(source_body);
    end

    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("MUTATING_SOURCE_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != requests.size() ||
        item_statuses.size() != requests.size())
      `uvm_error("MUTATING_SOURCE_ALIGNMENT", "outputs are misaligned")
    else begin
      foreach (requests[i]) begin
        expect_status($sformatf("MUTATING_SOURCE_ITEM_%0d", i),
                      item_statuses[i], RDMA_SC_INVALID_ARGUMENT);
        if (tickets[i] != null)
          `uvm_error("MUTATING_SOURCE_TICKET",
                     $sformatf("item %0d returned a ticket", i))
      end
    end
    foreach (requests[i]) begin
      if (requests[i].function_h != saved_function_refs[i] ||
          requests[i].opcode_key != saved_opcode_refs[i] ||
          requests[i].body != saved_body_refs[i] ||
          requests[i].qpc_signature_source != saved_signature_refs[i] ||
          requests[i].vfid_override != saved_vfid_override[i] ||
          requests[i].use_vfid != saved_use_vfid[i] ||
          requests[i].timeout != saved_timeout[i] ||
          !engine.probe_same_handle(requests[i].function_h,
                                    saved_function_values[i]) ||
          !engine.probe_same_opcode(requests[i].opcode_key,
                                    saved_opcode_values[i]) ||
          !engine.probe_same_image(requests[i].qpc_signature_source,
                                   saved_signature_values[i]))
        `uvm_error("MUTATING_SOURCE_ROOT",
                   $sformatf("item %0d changed its command root", i))
      if (!$cast(source_body, requests[i].body)) begin
        `uvm_error("MUTATING_SOURCE_BODY",
                   $sformatf("item %0d lost its SQE body", i))
      end
      else if (source_body.function_h != saved_body_function_refs[i] ||
               source_body.target_h != saved_body_target_refs[i] ||
               source_body.context_model != saved_body_context_refs[i] ||
               engine.probe_body_value_key(source_body) !=
                 saved_body_values[i])
        `uvm_error("MUTATING_SOURCE_BODY",
                   $sformatf("item %0d changed its SQE graph", i))
    end
    if (fault_body.flags != saved_outer_flags ||
        outer_qpc.host_id != saved_outer_host_id ||
        outer_qpc.qp_h != saved_outer_qp_h ||
        outer_qpc.pd_h != saved_outer_pd_h ||
        outer_qpc.send_cq_h != saved_outer_send_cq_h ||
        outer_qpc.recv_cq_h != saved_outer_recv_cq_h ||
        outer_qpc.srq_h != saved_outer_srq_h ||
        fault_handle.object_id != saved_nested_object_id ||
        nested_qpc.qp_h != saved_nested_qp_h ||
        nested_qpc.pd_h != saved_nested_pd_h ||
        nested_qpc.send_cq_h != saved_nested_send_cq_h ||
        nested_qpc.recv_cq_h != saved_nested_recv_cq_h ||
        nested_qpc.srq_h != saved_nested_srq_h ||
        fault_ring.index != saved_cqc_producer_index ||
        nested_cqc.cq_h != saved_cqc_cq_h ||
        nested_cqc.ceq_h != saved_cqc_ceq_h ||
        nested_cqc.page_layout != saved_cqc_page_layout ||
        nested_cqc.producer != saved_cqc_producer ||
        nested_cqc.consumer != saved_cqc_consumer)
      `uvm_error("MUTATING_SOURCE_NESTED",
                 "mutating clone changed a caller-owned nested graph")
    expect_no_submit_side_effects("MUTATING_SOURCE_EFFECTS", mem, pcie,
                                  trace);
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0)
      `uvm_error("MUTATING_SOURCE_LEDGER",
                 "mutating clone failure changed the authority ledger")

    clear_submit_observation(mem, pcie, trace);
    requests = new[1];
    requests[0] = make_command(
      "mutating_source_recovery", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'hd0
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("MUTATING_SOURCE_RECOVERY_BATCH", batch_status,
                  RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] == null ||
        item_statuses.size() != 1)
      `uvm_error("MUTATING_SOURCE_RECOVERY",
                 "source restoration failure contaminated recovery")
    else
      expect_status("MUTATING_SOURCE_RECOVERY_ITEM", item_statuses[0],
                    RDMA_SC_OK);
    if (engine.published_count() != 1 ||
        engine.tokens_in_use_count() != 1 ||
        engine.slot_record_count() != 1)
      `uvm_error("MUTATING_SOURCE_RECOVERY_LEDGER",
                 "source restoration failure polluted recovery state")

    engine.shutdown(status);
    expect_status("MUTATING_SOURCE_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_qpc_context_snapshot_failures 中构造或驱动“qpc context snapshot failures”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_qpc_context_snapshot_failures();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_sqe_model outer_body;
    rdma_qpc_model qpc;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;
    rdma_cmq_clone_fault_qpc fault_qpc;
    rdma_cmq_clone_fault_aeqc fault_aeqc;
    rdma_cmq_clone_fault_handle fault_handle;
    rdma_cmq_clone_fault_page_layout fault_page_layout;
    rdma_cmq_clone_fault_mr_page_layout fault_mr_page_layout;
    rdma_cmq_clone_fault_ring fault_ring;
    rdma_cmq_unknown_body unknown_body;
    rdma_cmq_copy_fatal_catcher catcher;
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("qpc_graph_engine");
    mem = rdma_mock_host_mem::type_id::create("qpc_graph_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("qpc_graph_pcie");
    trace = rdma_mock_call_trace::type_id::create("qpc_graph_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "qpc_graph_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("qpc_graph_profile");
    prepared_binding = make_binding("qpc_graph_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("qpc_graph_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("qpc_graph_cmq", prepared_binding);
    prepare_active("QPC_GRAPH", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[12];
    foreach (requests[i]) begin
      requests[i] = make_command(
        $sformatf("qpc_graph_%0d", i), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'h90 + i)
      );
      if (!$cast(outer_body, requests[i].body))
        `uvm_fatal("QPC_GRAPH_SETUP", "outer body type is invalid")
      outer_body.context_model = make_qpc_context(
        $sformatf("qpc_graph_context_%0d", i), active_binding
      );
    end

    if (!$cast(outer_body, requests[0].body) ||
        !$cast(qpc, outer_body.context_model))
      `uvm_fatal("QPC_GRAPH_SETUP", "null-clone QPC is invalid")
    fault_handle = rdma_cmq_clone_fault_handle::type_id::create(
      "qpc_nested_null"
    );
    fault_handle.copy(qpc.qp_h);
    fault_handle.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    qpc.qp_h = fault_handle;

    if (!$cast(outer_body, requests[1].body) ||
        !$cast(qpc, outer_body.context_model))
      `uvm_fatal("QPC_GRAPH_SETUP", "wrong-clone QPC is invalid")
    fault_handle = rdma_cmq_clone_fault_handle::type_id::create(
      "qpc_nested_wrong"
    );
    fault_handle.copy(qpc.qp_h);
    fault_handle.clone_fault = RDMA_CMQ_TEST_CLONE_WRONG_TYPE;
    qpc.qp_h = fault_handle;

    if (!$cast(outer_body, requests[2].body) ||
        !$cast(qpc, outer_body.context_model))
      `uvm_fatal("QPC_GRAPH_SETUP", "self-clone QPC is invalid")
    fault_handle = rdma_cmq_clone_fault_handle::type_id::create(
      "qpc_nested_self"
    );
    fault_handle.copy(qpc.qp_h);
    fault_handle.clone_fault = RDMA_CMQ_TEST_CLONE_SELF;
    qpc.qp_h = fault_handle;

    if (!$cast(outer_body, requests[3].body) ||
        !$cast(qpc, outer_body.context_model))
      `uvm_fatal("QPC_GRAPH_SETUP", "alias-clone QPC is invalid")
    fault_handle = rdma_cmq_clone_fault_handle::type_id::create(
      "qpc_nested_alias"
    );
    fault_handle.copy(qpc.send_cq_h);
    fault_handle.clone_fault = RDMA_CMQ_TEST_CLONE_ALIAS;
    fault_handle.alias_target = qpc.recv_cq_h;
    qpc.send_cq_h = fault_handle;

    if (!$cast(outer_body, requests[4].body) ||
        !$cast(qpc, outer_body.context_model))
      `uvm_fatal("QPC_GRAPH_SETUP", "mutating QPC is invalid")
    fault_qpc = rdma_cmq_clone_fault_qpc::type_id::create(
      "qpc_scalar_mutate"
    );
    fault_qpc.copy(qpc);
    fault_qpc.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    outer_body.context_model = fault_qpc;

    if (!$cast(outer_body, requests[5].body))
      `uvm_fatal("QPC_GRAPH_SETUP", "unknown outer body is invalid")
    unknown_body = rdma_cmq_unknown_body::type_id::create(
      "qpc_unknown_context"
    );
    outer_body.context_model = unknown_body;

    if (!$cast(outer_body, requests[6].body) ||
        !$cast(qpc, outer_body.context_model))
      `uvm_fatal("QPC_GRAPH_SETUP", "nested-mutation QPC is invalid")
    fault_handle = rdma_cmq_clone_fault_handle::type_id::create(
      "qpc_nested_mutate"
    );
    fault_handle.copy(qpc.qp_h);
    fault_handle.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    qpc.qp_h = fault_handle;

    if (!$cast(outer_body, requests[7].body))
      `uvm_fatal("QPC_GRAPH_SETUP", "CQC outer body is invalid")
    cqc = make_cqc_context("cqc_nested_null", active_binding);
    fault_page_layout =
      rdma_cmq_clone_fault_page_layout::type_id::create(
        "cqc_page_null"
      );
    fault_page_layout.copy(cqc.page_layout);
    fault_page_layout.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    cqc.page_layout = fault_page_layout;
    outer_body.context_model = cqc;

    if (!$cast(outer_body, requests[8].body))
      `uvm_fatal("QPC_GRAPH_SETUP", "MRT outer body is invalid")
    mrt = make_mrt_context("mrt_nested_wrong", active_binding);
    fault_mr_page_layout =
      rdma_cmq_clone_fault_mr_page_layout::type_id::create(
        "mrt_page_wrong"
      );
    fault_mr_page_layout.copy(mrt.page_layout);
    fault_mr_page_layout.clone_fault = RDMA_CMQ_TEST_CLONE_WRONG_TYPE;
    mrt.page_layout = fault_mr_page_layout;
    outer_body.context_model = mrt;

    if (!$cast(outer_body, requests[9].body))
      `uvm_fatal("QPC_GRAPH_SETUP", "SRQC outer body is invalid")
    srqc = make_srqc_context("srqc_nested_self", active_binding);
    fault_ring = rdma_cmq_clone_fault_ring::type_id::create(
      "srqc_producer_self"
    );
    fault_ring.copy(srqc.producer);
    fault_ring.clone_fault = RDMA_CMQ_TEST_CLONE_SELF;
    srqc.producer = fault_ring;
    outer_body.context_model = srqc;

    if (!$cast(outer_body, requests[10].body))
      `uvm_fatal("QPC_GRAPH_SETUP", "CEQC outer body is invalid")
    ceqc = make_ceqc_context("ceqc_nested_alias", active_binding);
    fault_ring = rdma_cmq_clone_fault_ring::type_id::create(
      "ceqc_producer_alias"
    );
    fault_ring.copy(ceqc.producer);
    fault_ring.clone_fault = RDMA_CMQ_TEST_CLONE_ALIAS;
    fault_ring.alias_target = ceqc.consumer;
    ceqc.producer = fault_ring;
    outer_body.context_model = ceqc;

    if (!$cast(outer_body, requests[11].body))
      `uvm_fatal("QPC_GRAPH_SETUP", "AEQC outer body is invalid")
    aeqc = make_aeqc_context("aeqc_scalar_mutate", active_binding);
    fault_aeqc = rdma_cmq_clone_fault_aeqc::type_id::create(
      "aeqc_context_mutate"
    );
    fault_aeqc.copy(aeqc);
    fault_aeqc.clone_fault = RDMA_CMQ_TEST_CLONE_MUTATE;
    outer_body.context_model = fault_aeqc;

    catcher = new("qpc_copy_fatal_catcher");
    uvm_report_cb::add(null, catcher);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    uvm_report_cb::delete(null, catcher);
    expect_status("QPC_GRAPH_BATCH", batch_status, RDMA_SC_OK);
    if (catcher.caught_count != 0)
      `uvm_error("QPC_GRAPH_FATAL",
                 $sformatf("snapshot validation reached %0d copy fatals",
                           catcher.caught_count))
    if (tickets.size() != requests.size() ||
        item_statuses.size() != requests.size())
      `uvm_error("QPC_GRAPH_ALIGNMENT", "QPC graph outputs misaligned")
    else begin
      foreach (requests[i]) begin
        expect_status($sformatf("QPC_GRAPH_ITEM_%0d", i),
                      item_statuses[i], RDMA_SC_INVALID_ARGUMENT);
        if (tickets[i] != null)
          `uvm_error("QPC_GRAPH_TICKET",
                     $sformatf("QPC graph item %0d returned a ticket", i))
      end
    end
    expect_no_submit_side_effects("QPC_GRAPH_EFFECTS", mem, pcie, trace);

    requests = new[6];
    foreach (requests[i]) begin
      requests[i] = make_command(
        $sformatf("context_valid_%0d", i), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hb0 + i)
      );
      if (!$cast(outer_body, requests[i].body))
        `uvm_fatal("QPC_GRAPH_SETUP", "valid outer body is invalid")
      case (i)
        0: outer_body.context_model =
             make_qpc_context("context_valid_qpc", active_binding);
        1: outer_body.context_model =
             make_cqc_context("context_valid_cqc", active_binding);
        2: outer_body.context_model =
             make_mrt_context("context_valid_mrt", active_binding);
        3: outer_body.context_model =
             make_srqc_context("context_valid_srqc", active_binding);
        4: outer_body.context_model =
             make_ceqc_context("context_valid_ceqc", active_binding);
        5: outer_body.context_model =
             make_aeqc_context("context_valid_aeqc", active_binding);
        default: begin
        end
      endcase
    end
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("CONTEXT_VALID_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != requests.size() ||
        item_statuses.size() != requests.size())
      `uvm_error("CONTEXT_VALID_ALIGNMENT",
                 "valid context outputs misaligned")
    else begin
      foreach (requests[i]) begin
        expect_status($sformatf("CONTEXT_VALID_ITEM_%0d", i),
                      item_statuses[i], RDMA_SC_OK);
        if (tickets[i] == null)
          `uvm_error("CONTEXT_VALID_TICKET",
                     $sformatf("valid context item %0d lacks a ticket", i))
      end
    end

    engine.shutdown(status);
    expect_status("QPC_GRAPH_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_null_compose_transaction_abort 中构造或驱动“null compose transaction abort”场景，并断言
  //   DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_null_compose_transaction_abort();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "null_compose_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("null_compose_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("null_compose_pcie");
    trace = rdma_mock_call_trace::type_id::create("null_compose_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "null_compose_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "null_compose_profile"
    );
    prepared_binding = make_binding("null_compose_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("null_compose_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("null_compose_cmq", prepared_binding);
    prepare_active("NULL_COMPOSE", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[6];
    requests[0] = make_command(
      "null_compose_invalid", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h40
    );
    requests[0].body = null;
    requests[1] = make_command(
      "null_compose_unsupported", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'h41
    );
    requests[2] = make_command(
      "null_compose_codec", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'h42
    );
    requests[3] = make_command(
      "null_compose_tentative", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h43
    );
    requests[4] = make_command(
      "null_compose_trigger", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h44
    );
    requests[5] = make_command(
      "null_compose_unprocessed", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h45
    );
    profile.fail_compose_opcode = rdma_cmq_test_profile::TEST_OPCODE_B;
    profile.null_compose_call = 4;

    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("NULL_COMPOSE_BATCH", batch_status,
                  RDMA_SC_INVALID_STATE);
    if (tickets.size() != requests.size() ||
        item_statuses.size() != requests.size())
      `uvm_error("NULL_COMPOSE_ALIGNMENT",
                 "null-compose outputs are misaligned")
    else begin
      expect_status("NULL_COMPOSE_INVALID", item_statuses[0],
                    RDMA_SC_INVALID_ARGUMENT);
      expect_status("NULL_COMPOSE_UNSUPPORTED", item_statuses[1],
                    RDMA_SC_UNSUPPORTED_OPCODE);
      expect_status("NULL_COMPOSE_CODEC", item_statuses[2],
                    RDMA_SC_CODEC_ERROR);
      for (int unsigned i = 3; i < requests.size(); i++)
        expect_status($sformatf("NULL_COMPOSE_ABORTED_%0d", i),
                      item_statuses[i], RDMA_SC_INVALID_STATE);
      foreach (tickets[i])
        if (tickets[i] != null)
          `uvm_error("NULL_COMPOSE_TICKET",
                     $sformatf("null-compose item %0d returned a ticket", i))
    end
    expect_no_submit_side_effects("NULL_COMPOSE_EFFECTS", mem, pcie,
                                  trace);
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error("NULL_COMPOSE_LEDGER",
                 "null compose status committed tentative state")

    profile.fail_compose_opcode = '0;
    clear_submit_observation(mem, pcie, trace);
    requests = new[1];
    requests[0] = make_command(
      "null_compose_recovery", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h46
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("NULL_COMPOSE_RECOVERY_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] == null ||
        item_statuses.size() != 1)
      `uvm_error("NULL_COMPOSE_RECOVERY",
                 "submission did not recover after null compose status")
    else
      expect_status("NULL_COMPOSE_RECOVERY_ITEM", item_statuses[0],
                    RDMA_SC_OK);

    engine.shutdown(status);
    expect_status("NULL_COMPOSE_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_transaction_failure_atomicity 中构造或驱动“transaction failure atomicity”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_transaction_failure_atomicity();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("atomic_engine");
    mem = rdma_mock_host_mem::type_id::create("atomic_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("atomic_pcie");
    trace = rdma_mock_call_trace::type_id::create("atomic_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create("atomic_scheduler");
    profile = rdma_cmq_test_profile::type_id::create("atomic_profile");
    prepared_binding = make_binding("atomic_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("atomic_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("atomic_cmq", prepared_binding);
    prepare_active("ATOMIC", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[3];
    requests[0] = make_command("atomic_a", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h51);
    requests[1] = make_command(
      "atomic_unsupported", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'h52
    );
    requests[2] = make_command("atomic_b", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_B, 8'h53);

    profile.fail_doorbell_encode = 1'b1;
    profile.doorbell_failure_code = RDMA_SC_CODEC_ERROR;
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("ATOMIC_ENCODE_BATCH", batch_status, RDMA_SC_CODEC_ERROR);
    if (tickets.size() != 3 || item_statuses.size() != 3)
      `uvm_error("ATOMIC_ENCODE_ALIGNMENT", "encode outputs misaligned")
    else begin
      expect_status("ATOMIC_ENCODE_A", item_statuses[0],
                    RDMA_SC_CODEC_ERROR);
      expect_status("ATOMIC_ENCODE_UNSUPPORTED", item_statuses[1],
                    RDMA_SC_UNSUPPORTED_OPCODE);
      expect_status("ATOMIC_ENCODE_B", item_statuses[2],
                    RDMA_SC_CODEC_ERROR);
      foreach (tickets[i])
        if (tickets[i] != null)
          `uvm_error("ATOMIC_ENCODE_TICKET",
                     "encode failure published a tentative ticket")
    end
    expect_no_submit_side_effects("ATOMIC_ENCODE_EFFECTS", mem, pcie,
                                  trace);
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error("ATOMIC_ENCODE_LEDGER",
                 "encode failure committed tentative state")

    profile.fail_doorbell_encode = 1'b0;
    clear_submit_observation(mem, pcie, trace);
    expect_status("ATOMIC_FAIL_INJECT",
                  pcie.fail_next(
                    "mmio_write",
                    rdma_status::make(RDMA_SC_TIMEOUT,
                                      "injected transport failure")
                  ), RDMA_SC_OK);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("ATOMIC_TRANSPORT_BATCH", batch_status, RDMA_SC_TIMEOUT);
    if (tickets.size() != 3 || item_statuses.size() != 3)
      `uvm_error("ATOMIC_TRANSPORT_ALIGNMENT", "transport outputs misaligned")
    else begin
      expect_status("ATOMIC_TRANSPORT_A", item_statuses[0], RDMA_SC_TIMEOUT);
      expect_status("ATOMIC_TRANSPORT_UNSUPPORTED", item_statuses[1],
                    RDMA_SC_UNSUPPORTED_OPCODE);
      expect_status("ATOMIC_TRANSPORT_B", item_statuses[2], RDMA_SC_TIMEOUT);
      foreach (tickets[i])
        if (tickets[i] != null)
          `uvm_error("ATOMIC_TRANSPORT_TICKET",
                     "transport failure published a tentative ticket")
    end
    if (mem.calls.size() != 2 || pcie.calls.size() != 3 ||
        pcie.calls[2].method_name != "mmio_write")
      `uvm_error("ATOMIC_TRANSPORT_PATH",
                 "transport failure did not reach the final doorbell")
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error("ATOMIC_TRANSPORT_LEDGER",
                 "scheduler failure committed tentative state")

    // A failed scheduler transaction must not commit the tentative CMQ
    // profile format.  Recovery is allowed to establish a different one.
    profile.sqe_endian = RDMA_ENDIAN_LITTLE;
    profile.sqe_hardware_version = 11;
    clear_submit_observation(mem, pcie, trace);
    requests = new[1];
    requests[0] = make_command("atomic_recovery", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h61);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("ATOMIC_RECOVERY_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] == null ||
        item_statuses.size() != 1)
      `uvm_error("ATOMIC_RECOVERY", "recovery submission did not publish")
    else begin
      expect_status("ATOMIC_RECOVERY_ITEM", item_statuses[0], RDMA_SC_OK);
      if (tickets[0].slot_sequence != 0 || tickets[0].sq_index != 0 ||
          tickets[0].command_id[4:0] != 0 ||
          tickets[0].command_id[63:5] != 3)
        `uvm_error("ATOMIC_RECOVERY_ID",
                   "rollback reused slot/token without advancing incarnation")
    end

    profile.fail_compose_opcode = rdma_cmq_test_profile::TEST_OPCODE_B;
    clear_submit_observation(mem, pcie, trace);
    requests[0] = make_command("atomic_compose", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_B, 8'h62);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("ATOMIC_COMPOSE_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] != null ||
        item_statuses.size() != 1)
      `uvm_error("ATOMIC_COMPOSE", "compose failure output is not atomic")
    else
      expect_status("ATOMIC_COMPOSE_ITEM", item_statuses[0],
                    RDMA_SC_CODEC_ERROR);
    expect_no_submit_side_effects("ATOMIC_COMPOSE_EFFECTS", mem, pcie,
                                  trace);
    if (engine.published_count() != 1 ||
        engine.tokens_in_use_count() != 1 ||
        engine.slot_record_count() != 1 ||
        engine.command_registry_count() != 1 ||
        engine.entry_registry_count() != 1)
      `uvm_error("ATOMIC_COMPOSE_LEDGER",
                 "per-item compose failure changed committed state")

    engine.shutdown(status);
    expect_status("ATOMIC_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_profile_wide_cqe_format_authority 中构造或驱动“profile wide cqe format
  //   authority”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_profile_wide_cqe_format_authority();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("format_engine");
    mem = rdma_mock_host_mem::type_id::create("format_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("format_pcie");
    trace = rdma_mock_call_trace::type_id::create("format_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "format_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("format_profile");
    prepared_binding = make_binding("format_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("format_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("format_cmq", prepared_binding);
    prepare_active("FORMAT", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    profile.alternate_sqe_format_for_opcode_b = 1'b1;
    requests = new[2];
    requests[0] = make_command(
      "format_batch_a", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h71
    );
    requests[1] = make_command(
      "format_batch_b", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'h72
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("FORMAT_BATCH_STATUS", batch_status,
                  RDMA_SC_INVALID_STATE);
    if (tickets.size() != 2 || item_statuses.size() != 2)
      `uvm_error("FORMAT_BATCH_OUTPUT", "format failure outputs misaligned")
    else foreach (tickets[i]) begin
      if (tickets[i] != null)
        `uvm_error("FORMAT_BATCH_TICKET",
                   "inconsistent batch published a ticket")
      expect_status($sformatf("FORMAT_BATCH_ITEM_%0d", i),
                    item_statuses[i], RDMA_SC_INVALID_STATE);
    end
    expect_no_submit_side_effects("FORMAT_BATCH_EFFECTS", mem, pcie,
                                  trace);
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error("FORMAT_BATCH_LEDGER",
                 "inconsistent batch polluted the committed ledger")

    profile.alternate_sqe_format_for_opcode_b = 1'b0;
    clear_submit_observation(mem, pcie, trace);
    requests = new[1];
    requests[0] = make_command(
      "format_authority", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h73
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("FORMAT_AUTHORITY_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] == null ||
        item_statuses.size() != 1)
      `uvm_error("FORMAT_AUTHORITY_OUTPUT",
                 "format authority submission did not publish")
    else
      expect_status("FORMAT_AUTHORITY_ITEM", item_statuses[0], RDMA_SC_OK);

    profile.sqe_endian = RDMA_ENDIAN_LITTLE;
    profile.sqe_hardware_version = 12;
    clear_submit_observation(mem, pcie, trace);
    requests[0] = make_command(
      "format_change", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h74
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("FORMAT_CHANGE_BATCH", batch_status,
                  RDMA_SC_INVALID_STATE);
    if (tickets.size() != 1 || tickets[0] != null ||
        item_statuses.size() != 1)
      `uvm_error("FORMAT_CHANGE_OUTPUT",
                 "cross-batch format failure output is invalid")
    else
      expect_status("FORMAT_CHANGE_ITEM", item_statuses[0],
                    RDMA_SC_INVALID_STATE);
    expect_no_submit_side_effects("FORMAT_CHANGE_EFFECTS", mem, pcie,
                                  trace);
    if (engine.published_count() != 1 ||
        engine.tokens_in_use_count() != 1 ||
        engine.slot_record_count() != 1 ||
        engine.command_registry_count() != 1 ||
        engine.entry_registry_count() != 1)
      `uvm_error("FORMAT_CHANGE_LEDGER",
                 "cross-batch format change polluted committed authority")

    engine.shutdown(status);
    expect_status("FORMAT_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_all_transport_failure_rollbacks 中构造或驱动“all transport failure rollbacks”场景，并断言
  //   DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_all_transport_failure_rollbacks();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_cmq_ticket baseline_ticket;
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status injected;
    rdma_status status;
    longint unsigned baseline_command_id;
    string baseline_expected_variant;
    string label;

    for (int unsigned fault = 0; fault < 4; fault++) begin
      label = $sformatf("TRANSPORT_ROLLBACK_%0d", fault);
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("transport_rollback_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("transport_rollback_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("transport_rollback_pcie_%0d", fault)
      );
      trace = rdma_mock_call_trace::type_id::create(
        $sformatf("transport_rollback_trace_%0d", fault)
      );
      mem.set_call_trace(trace);
      pcie.set_call_trace(trace);
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("transport_rollback_scheduler_%0d", fault)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("transport_rollback_profile_%0d", fault)
      );
      prepared_binding = make_binding(
        $sformatf("transport_rollback_prepared_%0d", fault),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("transport_rollback_active_%0d", fault),
        RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("transport_rollback_cmq_%0d", fault),
                     prepared_binding);
      prepare_active(label, engine, mem, pcie, scheduler, profile,
                     prepared_binding, active_binding, cmq, runtime_desc);
      clear_submit_observation(mem, pcie, trace);
      baseline_ticket = null;
      baseline_command_id = '0;
      baseline_expected_variant = "";

      requests = new[1];
      requests[0] = make_command(
        $sformatf("transport_baseline_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'h60 + fault)
      );
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status({label, "_BASELINE_BATCH"}, batch_status, RDMA_SC_OK);
      if (tickets.size() != 1 || tickets[0] == null ||
          item_statuses.size() != 1)
        `uvm_error("TRANSPORT_ROLLBACK_BASELINE",
                   $sformatf("%s baseline output is invalid", label))
      else begin
        expect_status({label, "_BASELINE_ITEM"}, item_statuses[0],
                      RDMA_SC_OK);
        baseline_ticket = tickets[0];
        baseline_command_id = tickets[0].command_id;
        baseline_expected_variant = engine.slot_expected_variant(0);
        if (tickets[0].slot_sequence != 0 || tickets[0].sq_index != 0 ||
            tickets[0].sq_wrap || baseline_command_id == 0 ||
            baseline_expected_variant == "")
          `uvm_error("TRANSPORT_ROLLBACK_BASELINE_AUTHORITY",
                     $sformatf("%s baseline authority is invalid", label))
      end
      clear_submit_observation(mem, pcie, trace);

      requests = new[4];
      requests[0] = make_command(
        $sformatf("transport_rollback_a_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'h70 + fault)
      );
      requests[1] = make_command(
        $sformatf("transport_rollback_invalid_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED,
        byte'(8'h80 + fault)
      );
      requests[2] = make_command(
        $sformatf("transport_rollback_codec_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_B, byte'(8'h90 + fault)
      );
      requests[3] = make_command(
        $sformatf("transport_rollback_b_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'ha0 + fault)
      );
      profile.fail_compose_opcode = rdma_cmq_test_profile::TEST_OPCODE_B;
      profile.compose_failure_code = RDMA_SC_CODEC_ERROR;
      injected = rdma_status::make(
        RDMA_SC_TIMEOUT, $sformatf("injected transport failure %0d", fault)
      );
      case (fault)
        0: expect_status({label, "_ARM_DEPENDENCY"},
                         mem.fail_write_at(2, injected), RDMA_SC_OK);
        1: expect_status(
             {label, "_ARM_DMA"},
             pcie.fail_next("dma_visibility_barrier", injected), RDMA_SC_OK
           );
        2: expect_status(
             {label, "_ARM_MMIO_BARRIER"},
             pcie.fail_next("mmio_ordering_barrier", injected), RDMA_SC_OK
           );
        3: expect_status(
             {label, "_ARM_MMIO_WRITE"},
             pcie.fail_next("mmio_write", injected), RDMA_SC_OK
           );
      endcase

      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status({label, "_BATCH"}, batch_status, RDMA_SC_TIMEOUT);
      if (tickets.size() != 4 || item_statuses.size() != 4)
        `uvm_error("TRANSPORT_ROLLBACK_ALIGNMENT",
                   $sformatf("%s outputs are misaligned", label))
      else begin
        expect_status({label, "_VALID_A"}, item_statuses[0],
                      RDMA_SC_TIMEOUT);
        expect_status({label, "_VALIDATION"}, item_statuses[1],
                      RDMA_SC_UNSUPPORTED_OPCODE);
        expect_status({label, "_CODEC"}, item_statuses[2],
                      RDMA_SC_CODEC_ERROR);
        expect_status({label, "_VALID_B"}, item_statuses[3],
                      RDMA_SC_TIMEOUT);
        foreach (tickets[i])
          if (tickets[i] != null)
            `uvm_error("TRANSPORT_ROLLBACK_TICKET",
                       $sformatf("%s published tentative ticket %0d",
                                 label, i))
      end
      if (mem.calls.size() != 2 || pcie.calls.size() != fault)
        `uvm_error("TRANSPORT_ROLLBACK_PATH",
                   $sformatf("%s observed host/PCIe calls %0d/%0d",
                             label, mem.calls.size(), pcie.calls.size()))
      if (engine.published_count() != 1 || engine.retired_count() != 0 ||
          engine.tokens_in_use_count() != 1 ||
          engine.slot_record_count() != 1 ||
          engine.command_registry_count() != 1 ||
          engine.entry_registry_count() != 1 || baseline_ticket == null ||
          baseline_ticket.command_id != baseline_command_id ||
          baseline_ticket.slot_sequence != 0 ||
          engine.slot_ticket_command_id(0) != baseline_command_id ||
          engine.slot_expected_variant(0) != baseline_expected_variant)
        `uvm_error("TRANSPORT_ROLLBACK_LEDGER",
                   $sformatf("%s changed committed authority", label))

      clear_submit_observation(mem, pcie, trace);
      profile.fail_compose_opcode = '0;
      requests = new[2];
      requests[0] = make_command(
        $sformatf("transport_recovery_a_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'ha0 + fault)
      );
      requests[1] = make_command(
        $sformatf("transport_recovery_b_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_B, byte'(8'hb0 + fault)
      );
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status({label, "_RECOVERY_BATCH"}, batch_status, RDMA_SC_OK);
      if (tickets.size() != 2 || tickets[0] == null || tickets[1] == null ||
          item_statuses.size() != 2)
        `uvm_error("TRANSPORT_ROLLBACK_RECOVERY",
                   $sformatf("%s recovery outputs are invalid", label))
      else begin
        expect_status({label, "_RECOVERY_A"}, item_statuses[0], RDMA_SC_OK);
        expect_status({label, "_RECOVERY_B"}, item_statuses[1], RDMA_SC_OK);
        if (tickets[0].slot_sequence != 1 || tickets[0].sq_index != 1 ||
            tickets[0].sq_wrap || tickets[1].slot_sequence != 2 ||
            tickets[1].sq_index != 2 || tickets[1].sq_wrap)
          `uvm_error("TRANSPORT_ROLLBACK_REUSE",
                     $sformatf("%s did not overwrite unpublished slots",
                               label))
      end
      if (mem.calls.size() != 2 || mem.calls[0].offset != 64 ||
          mem.calls[1].offset != 128 || engine.published_count() != 3 ||
          engine.tokens_in_use_count() != 3 ||
          engine.slot_record_count() != 3 ||
          engine.command_registry_count() != 3 ||
          engine.entry_registry_count() != 3 ||
          engine.slot_ticket_command_id(0) != baseline_command_id ||
          engine.slot_expected_variant(0) != baseline_expected_variant)
        `uvm_error("TRANSPORT_ROLLBACK_RECOVERY_LEDGER",
                   $sformatf("%s leaked or skipped recovered authority",
                             label))

      engine.shutdown(status);
      expect_status({label, "_SHUTDOWN"}, status, RDMA_SC_OK);
    end
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_doorbell_authority_isolation 中构造或驱动“doorbell authority isolation”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_doorbell_authority_isolation();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;

    for (int unsigned fault = RDMA_CMQ_TEST_DB_INPUT_MUTATE_SUCCESS;
         fault <= RDMA_CMQ_TEST_DB_INPUT_MUTATE_NULL; fault++) begin
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("doorbell_authority_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("doorbell_authority_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("doorbell_authority_pcie_%0d", fault)
      );
      trace = rdma_mock_call_trace::type_id::create(
        $sformatf("doorbell_authority_trace_%0d", fault)
      );
      mem.set_call_trace(trace);
      pcie.set_call_trace(trace);
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("doorbell_authority_scheduler_%0d", fault)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("doorbell_authority_profile_%0d", fault)
      );
      if (!$cast(profile.doorbell_input_fault, fault))
        `uvm_fatal("DOORBELL_AUTHORITY_SETUP",
                   "doorbell input fault enum cast failed")
      prepared_binding = make_binding(
        $sformatf("doorbell_authority_prepared_%0d", fault),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("doorbell_authority_active_%0d", fault),
        RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("doorbell_authority_cmq_%0d", fault),
                     prepared_binding);
      prepare_active($sformatf("DOORBELL_AUTHORITY_%0d", fault), engine,
                     mem, pcie, scheduler, profile, prepared_binding,
                     active_binding, cmq, runtime_desc);
      clear_submit_observation(mem, pcie, trace);

      requests = new[1];
      requests[0] = make_command(
        $sformatf("doorbell_authority_hostile_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hd0 + fault)
      );
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status($sformatf("DOORBELL_AUTHORITY_BATCH_%0d", fault),
                    batch_status, RDMA_SC_INVALID_STATE);
      if (tickets.size() != 1 || tickets[0] != null ||
          item_statuses.size() != 1)
        `uvm_error("DOORBELL_AUTHORITY_OUTPUT",
                   $sformatf("fault %0d published hostile output", fault))
      else
        expect_status($sformatf("DOORBELL_AUTHORITY_ITEM_%0d", fault),
                      item_statuses[0], RDMA_SC_INVALID_STATE);
      if (!engine.probe_authority_handle_matches(cmq.handle) ||
          engine.probe_is_authority_handle(profile.last_doorbell_input))
        `uvm_error("DOORBELL_AUTHORITY_HANDLE",
                   $sformatf("fault %0d exposed or changed authority", fault))
      expect_no_submit_side_effects(
        $sformatf("DOORBELL_AUTHORITY_EFFECTS_%0d", fault), mem, pcie,
        trace
      );
      if (engine.published_count() != 0 ||
          engine.tokens_in_use_count() != 0 ||
          engine.slot_record_count() != 0)
        `uvm_error("DOORBELL_AUTHORITY_LEDGER",
                   $sformatf("fault %0d committed tentative state", fault))

      profile.doorbell_input_fault = RDMA_CMQ_TEST_DB_INPUT_GOOD;
      clear_submit_observation(mem, pcie, trace);
      requests[0] = make_command(
        $sformatf("doorbell_authority_recovery_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'he0 + fault)
      );
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status($sformatf("DOORBELL_AUTHORITY_RECOVERY_BATCH_%0d",
                              fault), batch_status, RDMA_SC_OK);
      if (tickets.size() != 1 || tickets[0] == null ||
          item_statuses.size() != 1)
        `uvm_error("DOORBELL_AUTHORITY_RECOVERY",
                   $sformatf("fault %0d blocked recovery", fault))
      else
        expect_status($sformatf("DOORBELL_AUTHORITY_RECOVERY_ITEM_%0d",
                                fault), item_statuses[0], RDMA_SC_OK);
      if (engine.published_count() != 1 ||
          engine.tokens_in_use_count() != 1 ||
          engine.slot_record_count() != 1)
        `uvm_error("DOORBELL_AUTHORITY_RECOVERY_LEDGER",
                   $sformatf("fault %0d did not recover cleanly", fault))

      engine.shutdown(status);
      expect_status($sformatf("DOORBELL_AUTHORITY_SHUTDOWN_%0d", fault),
                    status, RDMA_SC_OK);
    end
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_submission_validation_and_profile_metadata 中构造或驱动“submission validation and
  //   profile metadata”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_submission_validation_and_profile_metadata();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_command_desc valid_clone_source;
    rdma_cmq_bad_clone_command bad_clone;
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;
    rdma_status_code_e expected_validation_codes[11] = '{
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_STALE_GENERATION,
      RDMA_SC_UNSUPPORTED_OPCODE,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT
    };
    rdma_status_code_e expected_sqe_codes[15] = '{
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_STALE_GENERATION,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_ARGUMENT,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE
    };
    rdma_status_code_e expected_db_codes[9] = '{
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE,
      RDMA_SC_INVALID_STATE
    };

    engine = rdma_cmq_engine_probe::type_id::create("validation_engine");
    mem = rdma_mock_host_mem::type_id::create("validation_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("validation_pcie");
    trace = rdma_mock_call_trace::type_id::create("validation_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "validation_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("validation_profile");
    prepared_binding = make_binding("validation_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("validation_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("validation_cmq", prepared_binding);
    prepare_active("VALIDATION", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[11];
    requests[0] = null;
    requests[1] = make_command("validation_body", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h01);
    requests[1].body = null;
    requests[2] = make_command("validation_kind", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h02);
    requests[2].function_h.kind = RDMA_RESOURCE_QP;
    requests[3] = make_command("validation_uid", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h03);
    requests[3].function_h.function_uid++;
    requests[4] = make_command("validation_object", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h04);
    requests[4].function_h.object_id++;
    requests[5] = make_command("validation_generation", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h05);
    requests[5].function_h.generation++;
    requests[6] = make_command("validation_profile", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h06);
    requests[6].opcode_key.profile_name = "wrong_profile";
    requests[7] = make_command("validation_timeout", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h07);
    requests[7].timeout = 0;
    bad_clone = rdma_cmq_bad_clone_command::type_id::create(
      "validation_null_clone"
    );
    valid_clone_source = make_command(
      "validation_null_clone_source", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h08
    );
    bad_clone.copy(valid_clone_source);
    requests[8] = bad_clone;
    bad_clone = rdma_cmq_bad_clone_command::type_id::create(
      "validation_wrong_clone"
    );
    valid_clone_source = make_command(
      "validation_wrong_clone_source", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h09
    );
    bad_clone.copy(valid_clone_source);
    bad_clone.return_wrong_type = 1'b1;
    requests[9] = bad_clone;
    bad_clone = rdma_cmq_bad_clone_command::type_id::create(
      "validation_self_clone"
    );
    valid_clone_source = make_command(
      "validation_self_clone_source", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h0a
    );
    bad_clone.copy(valid_clone_source);
    bad_clone.return_self = 1'b1;
    requests[10] = bad_clone;
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("VALIDATION_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != requests.size() ||
        item_statuses.size() != requests.size())
      `uvm_error("VALIDATION_ALIGNMENT", "validation outputs misaligned")
    else begin
      foreach (requests[i]) begin
        expect_status($sformatf("VALIDATION_ITEM_%0d", i), item_statuses[i],
                      expected_validation_codes[i]);
        if (tickets[i] != null)
          `uvm_error("VALIDATION_TICKET",
                     $sformatf("validation item %0d returned a ticket", i))
      end
    end
    expect_no_submit_side_effects("VALIDATION_EFFECTS", mem, pcie, trace);

    #1ns;
    clear_submit_observation(mem, pcie, trace);
    requests = new[1];
    requests[0] = make_command("validation_overflow", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h08);
    requests[0].timeout = time'(-1);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("VALIDATION_OVERFLOW_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] != null ||
        item_statuses.size() != 1)
      `uvm_error("VALIDATION_OVERFLOW", "deadline overflow output invalid")
    else
      expect_status("VALIDATION_OVERFLOW_ITEM", item_statuses[0],
                    RDMA_SC_INVALID_ARGUMENT);
    expect_no_submit_side_effects("VALIDATION_OVERFLOW_EFFECTS", mem, pcie,
                                  trace);

    clear_submit_observation(mem, pcie, trace);
    requests = new[2];
    requests[0] = make_command("validation_timeout_x", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h09);
    requests[0].timeout[7] = 1'bx;
    requests[1] = make_command("validation_timeout_z", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h0a);
    requests[1].timeout[11] = 1'bz;
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("VALIDATION_UNKNOWN_TIMEOUT_BATCH", batch_status,
                  RDMA_SC_OK);
    if (tickets.size() != 2 || item_statuses.size() != 2)
      `uvm_error("VALIDATION_UNKNOWN_TIMEOUT",
                 "unknown timeout outputs are misaligned")
    else begin
      foreach (tickets[i]) begin
        if (tickets[i] != null)
          `uvm_error("VALIDATION_UNKNOWN_TIMEOUT",
                     $sformatf("unknown timeout item %0d returned ticket", i))
        expect_status($sformatf("VALIDATION_UNKNOWN_TIMEOUT_%0d", i),
                      item_statuses[i], RDMA_SC_INVALID_ARGUMENT);
      end
    end
    expect_no_submit_side_effects("VALIDATION_UNKNOWN_TIMEOUT_EFFECTS",
                                  mem, pcie, trace);

    requests = new[1];
    for (int unsigned fault = 1; fault <= 15; fault++) begin
      clear_submit_observation(mem, pcie, trace);
      if (!$cast(profile.sqe_fault, fault))
        `uvm_fatal("VALIDATION_SETUP", "SQE fault enum cast failed")
      requests[0] = make_command($sformatf("sqe_fault_%0d", fault),
                                 active_binding,
                                 rdma_cmq_test_profile::TEST_OPCODE_A,
                                 byte'(8'h20 + fault));
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status($sformatf("SQE_FAULT_BATCH_%0d", fault), batch_status,
                    expected_sqe_codes[fault - 1]);
      if (tickets.size() != 1 || tickets[0] != null ||
          item_statuses.size() != 1)
        `uvm_error("SQE_FAULT_OUTPUT",
                   $sformatf("SQE fault %0d output invalid", fault))
      else
        expect_status($sformatf("SQE_FAULT_ITEM_%0d", fault),
                      item_statuses[0], expected_sqe_codes[fault - 1]);
      expect_no_submit_side_effects(
        $sformatf("SQE_FAULT_EFFECTS_%0d", fault), mem, pcie, trace
      );
    end
    profile.sqe_fault = RDMA_CMQ_TEST_SQE_GOOD;

    for (int unsigned fault = 1; fault <= 9; fault++) begin
      clear_submit_observation(mem, pcie, trace);
      if (!$cast(profile.doorbell_fault, fault))
        `uvm_fatal("VALIDATION_SETUP", "doorbell fault enum cast failed")
      requests[0] = make_command($sformatf("db_fault_%0d", fault),
                                 active_binding,
                                 rdma_cmq_test_profile::TEST_OPCODE_A,
                                 byte'(8'h40 + fault));
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status($sformatf("DB_FAULT_BATCH_%0d", fault), batch_status,
                    expected_db_codes[fault - 1]);
      if (tickets.size() != 1 || tickets[0] != null ||
          item_statuses.size() != 1)
        `uvm_error("DB_FAULT_OUTPUT",
                   $sformatf("doorbell fault %0d output invalid", fault))
      else
        expect_status($sformatf("DB_FAULT_ITEM_%0d", fault),
                      item_statuses[0], expected_db_codes[fault - 1]);
      expect_no_submit_side_effects(
        $sformatf("DB_FAULT_EFFECTS_%0d", fault), mem, pcie, trace
      );
    end
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0)
      `uvm_error("VALIDATION_LEDGER",
                 "rejected metadata changed engine ledger state")

    engine.shutdown(status);
    expect_status("VALIDATION_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_profile_hook_snapshot_contract 中构造或驱动“profile hook snapshot contract”场景，并断言
  //   DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_profile_hook_snapshot_contract();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_profile_hook_fault_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;
    rdma_cmq_copy_fatal_catcher catcher;

    for (int unsigned fault = RDMA_CMQ_TEST_HOOK_NULL_STATUS;
         fault <= RDMA_CMQ_TEST_HOOK_FAILED_VALIDATION; fault++) begin
      if (fault == RDMA_CMQ_TEST_HOOK_NONOK_STATUS)
        continue;
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("hook_contract_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("hook_contract_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("hook_contract_pcie_%0d", fault)
      );
      trace = rdma_mock_call_trace::type_id::create(
        $sformatf("hook_contract_trace_%0d", fault)
      );
      mem.set_call_trace(trace);
      pcie.set_call_trace(trace);
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("hook_contract_scheduler_%0d", fault)
      );
      profile = rdma_cmq_profile_hook_fault_profile::type_id::create(
        $sformatf("hook_contract_profile_%0d", fault)
      );
      if (!$cast(profile.snapshot_fault, fault))
        `uvm_fatal("HOOK_CONTRACT_SETUP", "hook fault enum cast failed")
      prepared_binding = make_binding(
        $sformatf("hook_contract_prepared_%0d", fault), RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("hook_contract_active_%0d", fault), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("hook_contract_cmq_%0d", fault),
                     prepared_binding);
      prepare_active($sformatf("HOOK_CONTRACT_%0d", fault), engine, mem,
                     pcie, scheduler, profile, prepared_binding,
                     active_binding, cmq, runtime_desc);
      clear_submit_observation(mem, pcie, trace);

      requests = new[4];
      requests[0] = null;
      requests[1] = make_command(
        $sformatf("hook_contract_unsupported_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'hd0
      );
      requests[2] = make_command(
        $sformatf("hook_contract_tentative_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, 8'hd1
      );
      requests[3] = make_command(
        $sformatf("hook_contract_trigger_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_B, 8'hd2
      );
      requests[3].body = make_profile_hook_body(
        $sformatf("hook_contract_body_%0d", fault), active_binding,
        32'h1234_0000 + fault
      );
      rdma_cmq_profile_hook_body::clear_hostile_clone_calls();
      catcher = new($sformatf("hook_contract_catcher_%0d", fault));
      uvm_report_cb::add(null, catcher);
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      uvm_report_cb::delete(null, catcher);

      expect_status($sformatf("HOOK_CONTRACT_BATCH_%0d", fault),
                    batch_status, RDMA_SC_INVALID_STATE);
      if (tickets.size() != 4 || item_statuses.size() != 4)
        `uvm_error("HOOK_CONTRACT_ALIGNMENT",
                   $sformatf("fault %0d outputs are misaligned", fault))
      else begin
        expect_status($sformatf("HOOK_CONTRACT_INVALID_%0d", fault),
                      item_statuses[0], RDMA_SC_INVALID_ARGUMENT);
        expect_status($sformatf("HOOK_CONTRACT_UNSUPPORTED_%0d", fault),
                      item_statuses[1], RDMA_SC_UNSUPPORTED_OPCODE);
        expect_status($sformatf("HOOK_CONTRACT_TENTATIVE_%0d", fault),
                      item_statuses[2], RDMA_SC_INVALID_STATE);
        expect_status($sformatf("HOOK_CONTRACT_TRIGGER_%0d", fault),
                      item_statuses[3], RDMA_SC_INVALID_STATE);
        foreach (tickets[i])
          if (tickets[i] != null)
            `uvm_error("HOOK_CONTRACT_TICKET",
                       $sformatf("fault %0d item %0d returned ticket",
                                 fault, i))
      end
      if (profile.snapshot_calls != 1)
        `uvm_error("HOOK_CONTRACT_CALLS",
                   $sformatf("fault %0d made %0d hook calls", fault,
                             profile.snapshot_calls))
      if (catcher.caught_count != 0 ||
          rdma_cmq_profile_hook_body::clone_call_count() != 0)
        `uvm_error("HOOK_CONTRACT_HOSTILE_CLONE",
                   $sformatf("fault %0d reached hostile clone (%0d/%0d)",
                             fault, catcher.caught_count,
                             rdma_cmq_profile_hook_body::clone_call_count()))
      expect_no_submit_side_effects(
        $sformatf("HOOK_CONTRACT_EFFECTS_%0d", fault), mem, pcie, trace
      );
      if (profile.doorbell_calls != 0)
        `uvm_error("HOOK_CONTRACT_DOORBELL",
                   $sformatf("fault %0d encoded a doorbell", fault))
      if (engine.published_count() != 0 ||
          engine.tokens_in_use_count() != 0 ||
          engine.slot_record_count() != 0)
        `uvm_error("HOOK_CONTRACT_LEDGER",
                   $sformatf("fault %0d committed tentative state", fault))

      engine.shutdown(status);
      expect_status($sformatf("HOOK_CONTRACT_SHUTDOWN_%0d", fault), status,
                    RDMA_SC_OK);
    end

    engine = rdma_cmq_engine_probe::type_id::create("hook_nonok_engine");
    mem = rdma_mock_host_mem::type_id::create("hook_nonok_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("hook_nonok_pcie");
    trace = rdma_mock_call_trace::type_id::create("hook_nonok_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "hook_nonok_scheduler"
    );
    profile = rdma_cmq_profile_hook_fault_profile::type_id::create(
      "hook_nonok_profile"
    );
    profile.snapshot_fault = RDMA_CMQ_TEST_HOOK_NONOK_STATUS;
    prepared_binding = make_binding("hook_nonok_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("hook_nonok_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("hook_nonok_cmq", prepared_binding);
    prepare_active("HOOK_NONOK", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);
    requests = new[2];
    requests[0] = make_command(
      "hook_nonok_unsupported", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'he0
    );
    requests[1] = make_command(
      "hook_nonok_rejected", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'he1
    );
    requests[1].body = make_profile_hook_body(
      "hook_nonok_body", active_binding, 32'h5678_0000
    );
    rdma_cmq_profile_hook_body::clear_hostile_clone_calls();
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("HOOK_NONOK_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 2 || item_statuses.size() != 2)
      `uvm_error("HOOK_NONOK_ALIGNMENT", "hook outputs are misaligned")
    else begin
      expect_status("HOOK_NONOK_UNSUPPORTED", item_statuses[0],
                    RDMA_SC_UNSUPPORTED_OPCODE);
      expect_status("HOOK_NONOK_REJECTED", item_statuses[1],
                    RDMA_SC_INVALID_STATE);
      foreach (tickets[i])
        if (tickets[i] != null)
          `uvm_error("HOOK_NONOK_TICKET", "rejected hook returned a ticket")
    end
    if (rdma_cmq_profile_hook_body::clone_call_count() != 0)
      `uvm_error("HOOK_NONOK_HOSTILE_CLONE",
                 "ordinary hook rejection reached hostile clone")
    expect_no_submit_side_effects("HOOK_NONOK_EFFECTS", mem, pcie, trace);
    if (engine.published_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0)
      `uvm_error("HOOK_NONOK_LEDGER", "hook rejection changed the ledger")
    engine.shutdown(status);
    expect_status("HOOK_NONOK_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_stateful_profile_snapshot_rechecks 中构造或驱动“stateful profile snapshot
  //   rechecks”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_stateful_profile_snapshot_rechecks();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_profile_hook_fault_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_command_desc trigger;
    rdma_cmq_profile_hook_body trigger_body;
    rdma_function_handle saved_function_h;
    rdma_cmq_opcode_key saved_opcode_key;
    rdma_hw_model saved_body;
    rdma_hw_image saved_signature;
    rdma_handle saved_nested_h;
    bit saved_vfid_override;
    bit [10:0] saved_use_vfid;
    time saved_timeout;
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;
    rdma_cmq_copy_fatal_catcher catcher;

    for (int unsigned fault = RDMA_CMQ_TEST_HOOK_STATEFUL_SAME_DRIFT;
         fault <= RDMA_CMQ_TEST_HOOK_STATEFUL_DETACH_DRIFT; fault++) begin
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("stateful_hook_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("stateful_hook_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("stateful_hook_pcie_%0d", fault)
      );
      trace = rdma_mock_call_trace::type_id::create(
        $sformatf("stateful_hook_trace_%0d", fault)
      );
      mem.set_call_trace(trace);
      pcie.set_call_trace(trace);
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("stateful_hook_scheduler_%0d", fault)
      );
      profile = rdma_cmq_profile_hook_fault_profile::type_id::create(
        $sformatf("stateful_hook_profile_%0d", fault)
      );
      if (!$cast(profile.snapshot_fault, fault))
        `uvm_fatal("STATEFUL_HOOK_SETUP", "hook fault enum cast failed")
      prepared_binding = make_binding(
        $sformatf("stateful_hook_prepared_%0d", fault), RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("stateful_hook_active_%0d", fault), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("stateful_hook_cmq_%0d", fault),
                     prepared_binding);
      prepare_active($sformatf("STATEFUL_HOOK_%0d", fault), engine, mem,
                     pcie, scheduler, profile, prepared_binding,
                     active_binding, cmq, runtime_desc);
      clear_submit_observation(mem, pcie, trace);

      requests = new[4];
      requests[0] = null;
      requests[1] = make_command(
        $sformatf("stateful_hook_unsupported_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'hf0
      );
      requests[2] = make_command(
        $sformatf("stateful_hook_tentative_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, 8'hf1
      );
      requests[3] = make_command(
        $sformatf("stateful_hook_trigger_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_B, 8'hf2
      );
      requests[3].body = make_profile_hook_body(
        $sformatf("stateful_hook_body_%0d", fault), active_binding,
        32'h9abc_0000 + fault
      );
      trigger = requests[3];
      if (!$cast(trigger_body, trigger.body))
        `uvm_fatal("STATEFUL_HOOK_SETUP", "stateful body cast failed")
      trigger_body.first_clone_succeeds = 1'b1;
      saved_function_h = trigger.function_h;
      saved_opcode_key = trigger.opcode_key;
      saved_body = trigger.body;
      saved_signature = trigger.qpc_signature_source;
      saved_nested_h = trigger_body.nested_h;
      saved_vfid_override = trigger.vfid_override;
      saved_use_vfid = trigger.use_vfid;
      saved_timeout = trigger.timeout;

      rdma_cmq_profile_hook_body::clear_hostile_clone_calls();
      catcher = new($sformatf("stateful_hook_catcher_%0d", fault));
      uvm_report_cb::add(null, catcher);
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      uvm_report_cb::delete(null, catcher);

      expect_status($sformatf("STATEFUL_HOOK_BATCH_%0d", fault),
                    batch_status, RDMA_SC_INVALID_STATE);
      if (tickets.size() != 4 || item_statuses.size() != 4)
        `uvm_error("STATEFUL_HOOK_ALIGNMENT",
                   $sformatf("fault %0d outputs are misaligned", fault))
      else begin
        expect_status($sformatf("STATEFUL_HOOK_INVALID_%0d", fault),
                      item_statuses[0], RDMA_SC_INVALID_ARGUMENT);
        expect_status($sformatf("STATEFUL_HOOK_UNSUPPORTED_%0d", fault),
                      item_statuses[1], RDMA_SC_UNSUPPORTED_OPCODE);
        expect_status($sformatf("STATEFUL_HOOK_TENTATIVE_%0d", fault),
                      item_statuses[2], RDMA_SC_INVALID_STATE);
        expect_status($sformatf("STATEFUL_HOOK_TRIGGER_%0d", fault),
                      item_statuses[3], RDMA_SC_INVALID_STATE);
        foreach (tickets[i])
          if (tickets[i] != null)
            `uvm_error("STATEFUL_HOOK_TICKET",
                       $sformatf("fault %0d item %0d returned ticket",
                                 fault, i))
      end
      if (catcher.caught_count != 0 || trigger_body.clone_calls != 1 ||
          rdma_cmq_profile_hook_body::clone_call_count() != 1)
        `uvm_error("STATEFUL_HOOK_CLONE",
                   $sformatf("fault %0d clone/fatal counts are %0d/%0d/%0d",
                             fault, catcher.caught_count,
                             trigger_body.clone_calls,
                             rdma_cmq_profile_hook_body::clone_call_count()))
      if (profile.same_calls != 2 ||
          profile.detach_calls !=
            ((fault == RDMA_CMQ_TEST_HOOK_STATEFUL_DETACH_DRIFT) ? 2 : 1))
        `uvm_error("STATEFUL_HOOK_PREDICATES",
                   $sformatf("fault %0d predicate counts are %0d/%0d",
                             fault, profile.same_calls,
                             profile.detach_calls))
      if (trigger.function_h != saved_function_h ||
          trigger.opcode_key != saved_opcode_key ||
          trigger.body != saved_body ||
          trigger.qpc_signature_source != saved_signature ||
          trigger_body.nested_h != saved_nested_h ||
          trigger.vfid_override != saved_vfid_override ||
          trigger.use_vfid != saved_use_vfid ||
          trigger.timeout != saved_timeout)
        `uvm_error("STATEFUL_HOOK_SOURCE",
                   $sformatf("fault %0d changed the caller command", fault))
      expect_no_submit_side_effects(
        $sformatf("STATEFUL_HOOK_EFFECTS_%0d", fault), mem, pcie, trace
      );
      if (profile.doorbell_calls != 0 || engine.published_count() != 0 ||
          engine.tokens_in_use_count() != 0 ||
          engine.slot_record_count() != 0)
        `uvm_error("STATEFUL_HOOK_LEDGER",
                   $sformatf("fault %0d published tentative state", fault))

      engine.shutdown(status);
      expect_status($sformatf("STATEFUL_HOOK_SHUTDOWN_%0d", fault), status,
                    RDMA_SC_OK);
    end
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_exact_type_profile_delegation 中构造或驱动“exact type profile delegation”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_exact_type_profile_delegation();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_profile_hook_fault_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_sqe_model command_body;
    rdma_cmq_scalar_extension_function_handle scalar_function_h;
    rdma_cmq_edge_extension_handle edge_target_h;
    rdma_handle saved_extension_h;
    int unsigned saved_extension_value;
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;

    for (int unsigned mode = 0; mode < 3; mode++) begin
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("exact_type_engine_%0d", mode)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("exact_type_mem_%0d", mode)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("exact_type_pcie_%0d", mode)
      );
      trace = rdma_mock_call_trace::type_id::create(
        $sformatf("exact_type_trace_%0d", mode)
      );
      mem.set_call_trace(trace);
      pcie.set_call_trace(trace);
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("exact_type_scheduler_%0d", mode)
      );
      profile = rdma_cmq_profile_hook_fault_profile::type_id::create(
        $sformatf("exact_type_profile_%0d", mode)
      );
      prepared_binding = make_binding(
        $sformatf("exact_type_prepared_%0d", mode), RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("exact_type_active_%0d", mode), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("exact_type_cmq_%0d", mode),
                     prepared_binding);
      prepare_active($sformatf("EXACT_TYPE_%0d", mode), engine, mem,
                     pcie, scheduler, profile, prepared_binding,
                     active_binding, cmq, runtime_desc);
      clear_submit_observation(mem, pcie, trace);

      requests = new[1];
      requests[0] = make_command(
        $sformatf("exact_type_request_%0d", mode), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hb0 + mode)
      );
      if (!$cast(command_body, requests[0].body))
        `uvm_fatal("EXACT_TYPE_SETUP", "command body cast failed")
      command_body.opcode = RDMA_CMQ_CREATE_QP;
      case (mode)
        0: command_body.context_model = make_qpc_context(
             "exact_type_builtin_qpc", active_binding
           );
        1: command_body.context_model = make_scalar_extension_qpc(
             "exact_type_scalar_qpc", active_binding, 32'h1357_9bdf
           );
        2: command_body.context_model = make_edge_extension_qpc(
             "exact_type_edge_qpc", active_binding
           );
        default:
          `uvm_fatal("EXACT_TYPE_SETUP", "unknown exact-type mode")
      endcase
      rdma_cmq_scalar_extension_qpc::clear_hostile_clone_calls();
      rdma_cmq_edge_extension_qpc::clear_hostile_clone_calls();
      engine.submit_batch(requests, tickets, item_statuses, batch_status);

      expect_status($sformatf("EXACT_TYPE_BATCH_%0d", mode), batch_status,
                    RDMA_SC_OK);
      if (tickets.size() != 1 || tickets[0] == null ||
          item_statuses.size() != 1)
        `uvm_error("EXACT_TYPE_OUTPUT",
                   $sformatf("mode %0d did not publish", mode))
      else
        expect_status($sformatf("EXACT_TYPE_ITEM_%0d", mode),
                      item_statuses[0], RDMA_SC_OK);
      if (mode == 0) begin
        if (profile.snapshot_calls != 0 || profile.same_calls != 0 ||
            profile.detach_calls != 0)
          `uvm_error("EXACT_TYPE_BUILTIN",
                     "exact built-in QPC unexpectedly used profile hooks")
      end
      else begin
        if (profile.snapshot_calls != 1 || profile.same_calls == 0 ||
            profile.detach_calls == 0)
          `uvm_error("EXACT_TYPE_EXTENSION",
                     $sformatf("mode %0d bypassed profile hooks (%0d/%0d/%0d)",
                               mode, profile.snapshot_calls,
                               profile.same_calls, profile.detach_calls))
        if (rdma_cmq_scalar_extension_qpc::clone_call_count() != 0 ||
            rdma_cmq_edge_extension_qpc::clone_call_count() != 0)
          `uvm_error("EXACT_TYPE_HOSTILE_CLONE",
                     $sformatf("mode %0d invoked an extension clone (%0d/%0d)",
                               mode,
                               rdma_cmq_scalar_extension_qpc::clone_call_count(),
                               rdma_cmq_edge_extension_qpc::clone_call_count()))
      end

      engine.shutdown(status);
      expect_status($sformatf("EXACT_TYPE_SHUTDOWN_%0d", mode), status,
                    RDMA_SC_OK);
    end

    for (int unsigned fault = RDMA_CMQ_TEST_EXTENSION_DROP_SCALAR;
         fault <= RDMA_CMQ_TEST_EXTENSION_MUTATE_SOURCE; fault++) begin
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("extension_contract_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("extension_contract_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("extension_contract_pcie_%0d", fault)
      );
      trace = rdma_mock_call_trace::type_id::create(
        $sformatf("extension_contract_trace_%0d", fault)
      );
      mem.set_call_trace(trace);
      pcie.set_call_trace(trace);
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("extension_contract_scheduler_%0d", fault)
      );
      profile = rdma_cmq_profile_hook_fault_profile::type_id::create(
        $sformatf("extension_contract_profile_%0d", fault)
      );
      if (!$cast(profile.extension_fault, fault))
        `uvm_fatal("EXTENSION_CONTRACT_SETUP",
                   "extension fault enum cast failed")
      prepared_binding = make_binding(
        $sformatf("extension_contract_prepared_%0d", fault),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("extension_contract_active_%0d", fault),
        RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("extension_contract_cmq_%0d", fault),
                     prepared_binding);
      prepare_active($sformatf("EXTENSION_CONTRACT_%0d", fault), engine,
                     mem, pcie, scheduler, profile, prepared_binding,
                     active_binding, cmq, runtime_desc);
      clear_submit_observation(mem, pcie, trace);

      requests = new[1];
      requests[0] = make_command(
        $sformatf("extension_contract_request_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hc0 + fault)
      );
      if (!$cast(command_body, requests[0].body))
        `uvm_fatal("EXTENSION_CONTRACT_SETUP", "command body cast failed")
      command_body.opcode = RDMA_CMQ_CREATE_QP;
      if (fault == RDMA_CMQ_TEST_EXTENSION_ALIAS_EDGE)
        command_body.context_model = make_edge_extension_qpc(
          $sformatf("extension_contract_edge_%0d", fault), active_binding
        );
      else
        command_body.context_model = make_scalar_extension_qpc(
          $sformatf("extension_contract_scalar_%0d", fault),
          active_binding, 32'h2468_ace0 + fault
        );
      rdma_cmq_scalar_extension_qpc::clear_hostile_clone_calls();
      rdma_cmq_edge_extension_qpc::clear_hostile_clone_calls();
      engine.submit_batch(requests, tickets, item_statuses, batch_status);

      expect_status($sformatf("EXTENSION_CONTRACT_BATCH_%0d", fault),
                    batch_status, RDMA_SC_INVALID_STATE);
      if (tickets.size() != 1 || tickets[0] != null ||
          item_statuses.size() != 1)
        `uvm_error("EXTENSION_CONTRACT_OUTPUT",
                   $sformatf("fault %0d published output", fault))
      else
        expect_status($sformatf("EXTENSION_CONTRACT_ITEM_%0d", fault),
                      item_statuses[0], RDMA_SC_INVALID_STATE);
      expect_no_submit_side_effects(
        $sformatf("EXTENSION_CONTRACT_EFFECTS_%0d", fault), mem, pcie,
        trace
      );
      if (engine.published_count() != 0 ||
          engine.tokens_in_use_count() != 0 ||
          engine.slot_record_count() != 0)
        `uvm_error("EXTENSION_CONTRACT_LEDGER",
                   $sformatf("fault %0d committed tentative state", fault))

      profile.extension_fault = RDMA_CMQ_TEST_EXTENSION_GOOD;
      clear_submit_observation(mem, pcie, trace);
      requests[0] = make_command(
        $sformatf("extension_contract_recovery_%0d", fault),
        active_binding, rdma_cmq_test_profile::TEST_OPCODE_A,
        byte'(8'hd0 + fault)
      );
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status($sformatf("EXTENSION_CONTRACT_RECOVERY_BATCH_%0d",
                              fault), batch_status, RDMA_SC_OK);
      if (tickets.size() != 1 || tickets[0] == null ||
          item_statuses.size() != 1)
        `uvm_error("EXTENSION_CONTRACT_RECOVERY",
                   $sformatf("fault %0d blocked recovery", fault))
      else
        expect_status($sformatf("EXTENSION_CONTRACT_RECOVERY_ITEM_%0d",
                                fault), item_statuses[0], RDMA_SC_OK);
      if (engine.published_count() != 1 ||
          engine.tokens_in_use_count() != 1 ||
          engine.slot_record_count() != 1)
        `uvm_error("EXTENSION_CONTRACT_RECOVERY_LEDGER",
                   $sformatf("fault %0d did not recover cleanly", fault))

      engine.shutdown(status);
      expect_status($sformatf("EXTENSION_CONTRACT_SHUTDOWN_%0d", fault),
                    status, RDMA_SC_OK);
    end

    for (int unsigned fault = RDMA_CMQ_TEST_DIRECT_HANDLE_DROP_SCALAR;
         fault <= RDMA_CMQ_TEST_DIRECT_HANDLE_DETACH_DRIFT; fault++) begin
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("direct_handle_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("direct_handle_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("direct_handle_pcie_%0d", fault)
      );
      trace = rdma_mock_call_trace::type_id::create(
        $sformatf("direct_handle_trace_%0d", fault)
      );
      mem.set_call_trace(trace);
      pcie.set_call_trace(trace);
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("direct_handle_scheduler_%0d", fault)
      );
      profile = rdma_cmq_profile_hook_fault_profile::type_id::create(
        $sformatf("direct_handle_profile_%0d", fault)
      );
      if (!$cast(profile.direct_handle_fault, fault))
        `uvm_fatal("DIRECT_HANDLE_SETUP",
                   "direct handle fault enum cast failed")
      prepared_binding = make_binding(
        $sformatf("direct_handle_prepared_%0d", fault),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("direct_handle_active_%0d", fault), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("direct_handle_cmq_%0d", fault),
                     prepared_binding);
      prepare_active($sformatf("DIRECT_HANDLE_%0d", fault), engine, mem,
                     pcie, scheduler, profile, prepared_binding,
                     active_binding, cmq, runtime_desc);
      clear_submit_observation(mem, pcie, trace);

      requests = new[1];
      requests[0] = make_command(
        $sformatf("direct_handle_request_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'he0 + fault)
      );
      if (!$cast(command_body, requests[0].body))
        `uvm_fatal("DIRECT_HANDLE_SETUP", "command body cast failed")
      scalar_function_h = null;
      edge_target_h = null;
      saved_extension_h = null;
      saved_extension_value = 0;
      if (fault inside {
            RDMA_CMQ_TEST_DIRECT_HANDLE_DROP_SCALAR,
            RDMA_CMQ_TEST_DIRECT_HANDLE_SAME_DRIFT
          }) begin
        scalar_function_h =
          rdma_cmq_scalar_extension_function_handle::type_id::create(
            $sformatf("direct_handle_scalar_%0d", fault)
          );
        scalar_function_h.copy(command_body.function_h);
        scalar_function_h.extension_value = 32'hcafe_0000 + fault;
        saved_extension_value = scalar_function_h.extension_value;
        command_body.function_h = scalar_function_h;
      end
      else begin
        edge_target_h = rdma_cmq_edge_extension_handle::type_id::create(
          $sformatf("direct_handle_edge_%0d", fault)
        );
        edge_target_h.copy(command_body.target_h);
        edge_target_h.extension_h = make_context_handle(
          $sformatf("direct_handle_edge_object_%0d", fault),
          active_binding, RDMA_RESOURCE_CMQ, TEST_CMQ_ID
        );
        saved_extension_h = edge_target_h.extension_h;
        command_body.target_h = edge_target_h;
      end

      engine.submit_batch(requests, tickets, item_statuses, batch_status);

      expect_status($sformatf("DIRECT_HANDLE_BATCH_%0d", fault),
                    batch_status, RDMA_SC_INVALID_STATE);
      if (tickets.size() != 1 || tickets[0] != null ||
          item_statuses.size() != 1)
        `uvm_error("DIRECT_HANDLE_OUTPUT",
                   $sformatf("fault %0d published output", fault))
      else
        expect_status($sformatf("DIRECT_HANDLE_ITEM_%0d", fault),
                      item_statuses[0], RDMA_SC_INVALID_STATE);
      if (profile.snapshot_calls != 1 || profile.same_calls != 2 ||
          profile.detach_calls !=
            ((fault inside {
                RDMA_CMQ_TEST_DIRECT_HANDLE_ALIAS_EDGE,
                RDMA_CMQ_TEST_DIRECT_HANDLE_DETACH_DRIFT
              }) ? 2 : 1))
        `uvm_error("DIRECT_HANDLE_HOOKS",
                   $sformatf("fault %0d hook counts are %0d/%0d/%0d",
                             fault, profile.snapshot_calls,
                             profile.same_calls, profile.detach_calls))
      if ((scalar_function_h != null &&
           (command_body.function_h != scalar_function_h ||
            scalar_function_h.extension_value != saved_extension_value)) ||
          (edge_target_h != null &&
           (command_body.target_h != edge_target_h ||
            edge_target_h.extension_h != saved_extension_h)))
        `uvm_error("DIRECT_HANDLE_SOURCE",
                   $sformatf("fault %0d changed the caller body", fault))
      expect_no_submit_side_effects(
        $sformatf("DIRECT_HANDLE_EFFECTS_%0d", fault), mem, pcie, trace
      );
      if (profile.doorbell_calls != 0)
        `uvm_error("DIRECT_HANDLE_DOORBELL",
                   $sformatf("fault %0d encoded a doorbell", fault))
      if (engine.published_count() != 0 ||
          engine.tokens_in_use_count() != 0 ||
          engine.slot_record_count() != 0)
        `uvm_error("DIRECT_HANDLE_LEDGER",
                   $sformatf("fault %0d committed tentative state", fault))

      profile.direct_handle_fault = RDMA_CMQ_TEST_DIRECT_HANDLE_GOOD;
      clear_submit_observation(mem, pcie, trace);
      requests[0] = make_command(
        $sformatf("direct_handle_recovery_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hf0 + fault)
      );
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status($sformatf("DIRECT_HANDLE_RECOVERY_BATCH_%0d", fault),
                    batch_status, RDMA_SC_OK);
      if (tickets.size() != 1 || tickets[0] == null ||
          item_statuses.size() != 1)
        `uvm_error("DIRECT_HANDLE_RECOVERY",
                   $sformatf("fault %0d blocked recovery", fault))
      else
        expect_status($sformatf("DIRECT_HANDLE_RECOVERY_ITEM_%0d", fault),
                      item_statuses[0], RDMA_SC_OK);
      if (engine.published_count() != 1 ||
          engine.tokens_in_use_count() != 1 ||
          engine.slot_record_count() != 1)
        `uvm_error("DIRECT_HANDLE_RECOVERY_LEDGER",
                   $sformatf("fault %0d did not recover cleanly", fault))

      engine.shutdown(status);
      expect_status($sformatf("DIRECT_HANDLE_SHUTDOWN_%0d", fault), status,
                    RDMA_SC_OK);
    end
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_internal_invariant_batch_abort 中构造或驱动“internal invariant batch abort”场景，并断言
  //   DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_internal_invariant_batch_abort();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;
    rdma_status_code_e expected_failure;

    configure_submission_factory_faults();
    disarm_submission_factory_faults();
    for (int unsigned fault = RDMA_CMQ_TEST_ABORT_SLOT_CONTEXT;
         fault <= RDMA_CMQ_TEST_ABORT_PROFILE_OUTPUT; fault++) begin
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("invariant_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("invariant_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("invariant_pcie_%0d", fault)
      );
      trace = rdma_mock_call_trace::type_id::create(
        $sformatf("invariant_trace_%0d", fault)
      );
      mem.set_call_trace(trace);
      pcie.set_call_trace(trace);
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("invariant_scheduler_%0d", fault)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("invariant_profile_%0d", fault)
      );
      prepared_binding = make_binding(
        $sformatf("invariant_prepared_%0d", fault), RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("invariant_active_%0d", fault), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("invariant_cmq_%0d", fault),
                     prepared_binding);
      prepare_active($sformatf("INVARIANT_%0d", fault), engine, mem, pcie,
                     scheduler, profile, prepared_binding, active_binding,
                     cmq, runtime_desc);
      clear_submit_observation(mem, pcie, trace);

      case (fault)
        RDMA_CMQ_TEST_ABORT_SLOT_CONTEXT:
          rdma_cmq_failing_slot_context::arm();
        RDMA_CMQ_TEST_ABORT_TICKET:
          rdma_cmq_failing_ticket::arm();
        RDMA_CMQ_TEST_ABORT_SLOT_RECORD:
          rdma_cmq_failing_slot_record::arm();
        RDMA_CMQ_TEST_ABORT_DEPENDENCY:
          rdma_cmq_failing_dependency::arm();
        RDMA_CMQ_TEST_ABORT_DOORBELL_DESC:
          rdma_cmq_failing_doorbell_desc::arm();
        RDMA_CMQ_TEST_ABORT_PROFILE_OUTPUT: begin
          profile.sqe_fault = RDMA_CMQ_TEST_SQE_BAD_ALIGNMENT;
          profile.sqe_fault_compose_call = 3;
        end
        default:
          `uvm_fatal("INVARIANT_SETUP", "unknown invariant fault")
      endcase
      expected_failure =
        (fault == RDMA_CMQ_TEST_ABORT_PROFILE_OUTPUT) ?
          RDMA_SC_INVALID_ARGUMENT : RDMA_SC_INVALID_STATE;

      requests = new[3];
      requests[0] = make_command(
        $sformatf("invariant_unsupported_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_UNSUPPORTED, 8'he0
      );
      requests[1] = make_command(
        $sformatf("invariant_success_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, 8'he1
      );
      requests[2] = make_command(
        $sformatf("invariant_trigger_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_B, 8'he2
      );
      engine.submit_batch(requests, tickets, item_statuses, batch_status);

      expect_status($sformatf("INVARIANT_BATCH_%0d", fault), batch_status,
                    expected_failure);
      if (tickets.size() != 3 || item_statuses.size() != 3)
        `uvm_error("INVARIANT_ALIGNMENT",
                   $sformatf("fault %0d outputs are misaligned", fault))
      else begin
        expect_status($sformatf("INVARIANT_UNSUPPORTED_%0d", fault),
                      item_statuses[0], RDMA_SC_UNSUPPORTED_OPCODE);
        expect_status($sformatf("INVARIANT_EARLY_SUCCESS_%0d", fault),
                      item_statuses[1], expected_failure);
        expect_status($sformatf("INVARIANT_TRIGGER_%0d", fault),
                      item_statuses[2], expected_failure);
        foreach (tickets[i])
          if (tickets[i] != null)
            `uvm_error("INVARIANT_TICKET",
                       $sformatf("fault %0d item %0d returned ticket",
                                 fault, i))
      end
      expect_no_submit_side_effects(
        $sformatf("INVARIANT_EFFECTS_%0d", fault), mem, pcie, trace
      );
      if (engine.published_count() != 0 ||
          engine.tokens_in_use_count() != 0 ||
          engine.slot_record_count() != 0)
        `uvm_error("INVARIANT_LEDGER",
                   $sformatf("fault %0d committed tentative state", fault))
      if (fault != RDMA_CMQ_TEST_ABORT_PROFILE_OUTPUT &&
          submission_factory_fault_armed())
        `uvm_error("INVARIANT_ARM",
                   $sformatf("fault %0d fixture was not exercised", fault))

      disarm_submission_factory_faults();
      profile.sqe_fault = RDMA_CMQ_TEST_SQE_GOOD;
      profile.sqe_fault_compose_call = 0;
      clear_submit_observation(mem, pcie, trace);
      requests = new[1];
      requests[0] = make_command(
        $sformatf("invariant_recovery_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hf0 + fault)
      );
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status($sformatf("INVARIANT_RECOVERY_BATCH_%0d", fault),
                    batch_status, RDMA_SC_OK);
      if (tickets.size() != 1 || tickets[0] == null ||
          item_statuses.size() != 1)
        `uvm_error("INVARIANT_RECOVERY",
                   $sformatf("fault %0d contaminated recovery", fault))
      else
        expect_status($sformatf("INVARIANT_RECOVERY_ITEM_%0d", fault),
                      item_statuses[0], RDMA_SC_OK);

      engine.shutdown(status);
      expect_status($sformatf("INVARIANT_SHUTDOWN_%0d", fault), status,
                    RDMA_SC_OK);
    end
    disarm_submission_factory_faults();
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_timeout_quarantine_and_late_diagnostic 中构造或驱动“timeout quarantine and late
  //   diagnostic”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_timeout_quarantine_and_late_diagnostic();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_command_desc reuse_request;
    rdma_cmq_ticket tickets[];
    rdma_cmq_ticket reuse_ticket;
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_dma_mapping mapping;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image first_raw;
    rdma_hw_image reuse_raw;
    rdma_hw_image survivor_raw;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("timeout_engine");
    mem = rdma_mock_host_mem::type_id::create("timeout_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("timeout_pcie");
    trace = rdma_mock_call_trace::type_id::create("timeout_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "timeout_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("timeout_profile");
    prepared_binding = make_binding("timeout_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("timeout_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("timeout_cmq", prepared_binding);
    prepare_active("TIMEOUT", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[2];
    requests[0] = make_command(
      "timeout_first", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'hd0, 10ns
    );
    requests[1] = make_command(
      "timeout_survivor", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'hd1, 1us
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("TIMEOUT_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 2 || item_statuses.size() != 2 ||
        tickets[0] == null || tickets[1] == null) begin
      `uvm_error("TIMEOUT_BATCH", "timeout batch outputs are incomplete")
      engine.shutdown(status);
      return;
    end
    expect_status("TIMEOUT_ITEM_0", item_statuses[0], RDMA_SC_OK);
    expect_status("TIMEOUT_ITEM_1", item_statuses[1], RDMA_SC_OK);
    if (tickets[0].command_id[4:0] != 0 ||
        tickets[1].command_id[4:0] != 1)
      `uvm_error("TIMEOUT_TOKEN_ORDER", "initial token order is unexpected")
    mapping = engine.mapping_snapshot();

    #20ns;
    engine.expire(completions, status);
    expect_status("TIMEOUT_EXPIRE", status, RDMA_SC_OK);
    if (completions.size() != 1)
      `uvm_error("TIMEOUT_EXPIRE", "expire did not return exactly one result")
    else
      expect_timeout_completion("TIMEOUT_RESULT", completions[0], tickets[0]);
    if (engine.slot_state_at(0) != CMQ_SLOT_TIMED_OUT_QUARANTINED ||
        engine.slot_state_at(1) != CMQ_SLOT_PUBLISHED ||
        engine.published_count() != 2 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0 ||
        engine.tokens_in_use_count() != 1 ||
        engine.command_registry_count() != 1 ||
        engine.entry_registry_count() != 2 ||
        engine.slot_record_count() != 2)
      `uvm_error("TIMEOUT_QUARANTINE",
                 "partial expiry changed the quarantine ledger incorrectly")

    engine.expire(completions, status);
    expect_status("TIMEOUT_EXPIRE_AGAIN", status, RDMA_SC_OK);
    if (completions.size() != 0)
      `uvm_error("TIMEOUT_EXPIRE_AGAIN",
                 "timeout completion was delivered more than once")

    clear_submit_observation(mem, pcie, trace);
    reuse_request = make_command(
      "timeout_reuse", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'hd2, 10ns
    );
    engine.submit(reuse_request, reuse_ticket, status);
    expect_status("TIMEOUT_REUSE", status, RDMA_SC_OK);
    if (reuse_ticket == null)
      `uvm_error("TIMEOUT_REUSE", "reused token returned no ticket")
    else if (reuse_ticket.command_id[4:0] != tickets[0].command_id[4:0] ||
             reuse_ticket.command_id == tickets[0].command_id ||
             reuse_ticket.command_id[63:5] <= tickets[0].command_id[63:5])
      `uvm_error("TIMEOUT_REUSE",
                 "token reuse did not advance the full command incarnation")

    mem.calls.delete();
    write_profile_cqe(
      "TIMEOUT_LATE_FIRST", mem, mapping, profile, 0, 1'b1, tickets[0],
      0, first_raw
    );
    engine.poll(completions, diagnostics, status);
    expect_status("TIMEOUT_LATE_FIRST_POLL", status, RDMA_SC_OK);
    if (completions.size() != 0 || diagnostics.size() != 1)
      `uvm_error("TIMEOUT_LATE_FIRST_POLL",
                 "late CQE was not converted to one diagnostic")
    else
      expect_late_diagnostic("TIMEOUT_LATE_FIRST_DIAG", engine,
                             diagnostics[0], tickets[0], first_raw);
    if (reuse_ticket != null &&
        (!engine.token_in_use_at(reuse_ticket.command_id[4:0]) ||
         engine.command_registry_count() != 2 ||
         engine.tokens_in_use_count() != 2 ||
         engine.retired_count() != 1 ||
         engine.cq_consumed_count() != 1))
      `uvm_error("TIMEOUT_LATE_TOKEN",
                 "late CQE reclaimed the token's newer incarnation")

    engine.poll(completions, diagnostics, status);
    expect_status("TIMEOUT_LATE_REPEAT_POLL", status, RDMA_SC_OK);
    if (completions.size() != 0 || diagnostics.size() != 0 ||
        engine.cq_consumed_count() != 1)
      `uvm_error("TIMEOUT_LATE_REPEAT_POLL",
                 "consumed late CQE was delivered more than once")

    if (reuse_ticket != null) begin
      mem.calls.delete();
      write_profile_cqe(
        "TIMEOUT_READY_AT_DEADLINE", mem, mapping, profile, 1, 1'b1,
        reuse_ticket, 0, reuse_raw
      );
      #20ns;
      engine.poll(completions, diagnostics, status);
      expect_status("TIMEOUT_READY_AT_DEADLINE_POLL", status, RDMA_SC_OK);
      if (completions.size() != 1 || diagnostics.size() != 1)
        `uvm_error("TIMEOUT_READY_AT_DEADLINE_POLL",
                   "deadline-ready CQE was not expired before inspection")
      else begin
        expect_timeout_completion("TIMEOUT_READY_AT_DEADLINE_RESULT",
                                  completions[0], reuse_ticket);
        expect_late_diagnostic("TIMEOUT_READY_AT_DEADLINE_DIAG", engine,
                               diagnostics[0], reuse_ticket, reuse_raw);
      end
      if (engine.slot_state_at(reuse_ticket.sq_index) !=
            CMQ_SLOT_LATE_COMPLETED ||
          engine.retired_count() != 1 ||
          engine.cq_consumed_count() != 2 ||
          engine.command_registry_count() != 1 ||
          engine.tokens_in_use_count() != 1 ||
          engine.entry_registry_count() != 2)
        `uvm_error("TIMEOUT_READY_AT_DEADLINE_LEDGER",
                   "deadline-ready late completion ledger is inconsistent")
    end

    mem.calls.delete();
    write_profile_cqe(
      "TIMEOUT_SURVIVOR_CQE", mem, mapping, profile, 2, 1'b1, tickets[1],
      0, survivor_raw
    );
    engine.poll(completions, diagnostics, status);
    expect_status("TIMEOUT_SURVIVOR_POLL", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0)
      `uvm_error("TIMEOUT_SURVIVOR_POLL",
                 "unexpired survivor did not complete normally")
    else
      expect_polled_completion(
        "TIMEOUT_SURVIVOR_RESULT", engine, completions[0], tickets[1],
        survivor_raw, 1'b1, 0, RDMA_SC_OK
      );
    if (engine.published_count() != 3 || engine.retired_count() != 3 ||
        engine.cq_consumed_count() != 3 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error("TIMEOUT_FINAL_LEDGER",
                 "normal survivor did not retire the late-completed prefix")

    engine.shutdown(status);
    expect_status("TIMEOUT_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_expire_snapshot_failure_is_atomic_and_retryable 中构造或驱动“expire snapshot
  //   failure is atomic and retryable”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_expire_snapshot_failure_is_atomic_and_retryable();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_cmq_completion completions[$];
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "expire_snapshot_failure_engine"
    );
    mem = rdma_mock_host_mem::type_id::create(
      "expire_snapshot_failure_mem"
    );
    pcie = rdma_cmq_test_pcie::type_id::create(
      "expire_snapshot_failure_pcie"
    );
    trace = rdma_mock_call_trace::type_id::create(
      "expire_snapshot_failure_trace"
    );
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "expire_snapshot_failure_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "expire_snapshot_failure_profile"
    );
    prepared_binding = make_binding(
      "expire_snapshot_failure_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "expire_snapshot_failure_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("expire_snapshot_failure_cmq", prepared_binding);
    prepare_active(
      "EXPIRE_SNAPSHOT_FAILURE", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    clear_submit_observation(mem, pcie, trace);

    requests = new[2];
    requests[0] = make_command(
      "expire_snapshot_failure_request_0", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'hd8, 10ns
    );
    requests[1] = make_command(
      "expire_snapshot_failure_request_1", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'hd9, 10ns
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("EXPIRE_SNAPSHOT_FAILURE_SUBMIT", batch_status, RDMA_SC_OK);
    if (tickets.size() != 2 || item_statuses.size() != 2 ||
        tickets[0] == null || tickets[1] == null) begin
      `uvm_error("EXPIRE_SNAPSHOT_FAILURE_SUBMIT",
                 "two-command timeout fixture is incomplete")
      engine.shutdown(status);
      return;
    end
    expect_status("EXPIRE_SNAPSHOT_FAILURE_ITEM_0", item_statuses[0],
                  RDMA_SC_OK);
    expect_status("EXPIRE_SNAPSHOT_FAILURE_ITEM_1", item_statuses[1],
                  RDMA_SC_OK);

    if (!engine.install_slot_ticket_function_clone_fault(
          tickets[1].sq_index, RDMA_CMQ_TEST_CLONE_NULL
        ))
      `uvm_error("EXPIRE_SNAPSHOT_FAILURE_INJECT",
                 "could not inject the second ticket snapshot fault")
    rdma_cmq_clone_fault_function_handle::clear_fault_clone_calls();
    #20ns;
    engine.expire(completions, status);
    expect_status("EXPIRE_SNAPSHOT_FAILURE_STATUS", status,
                  RDMA_SC_INVALID_STATE);
    if (rdma_cmq_clone_fault_function_handle::fault_clone_call_count() != 1)
      `uvm_error("EXPIRE_SNAPSHOT_FAILURE_HIT",
                 "the second timeout ticket fault was not exercised once")
    if (completions.size() != 0 || engine.terminal_fifo_count() != 0 ||
        engine.diagnostic_fifo_count() != 0 ||
        engine.published_count() != 2 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0 ||
        engine.tokens_in_use_count() != 2 ||
        engine.slot_record_count() != 2 ||
        engine.command_registry_count() != 2 ||
        engine.entry_registry_count() != 2 ||
        engine.slot_state_at(tickets[0].sq_index) != CMQ_SLOT_PUBLISHED ||
        engine.slot_state_at(tickets[1].sq_index) != CMQ_SLOT_PUBLISHED)
      `uvm_error("EXPIRE_SNAPSHOT_FAILURE_ATOMIC",
                 "later timeout snapshot failure partially mutated authority")

    if (!engine.set_slot_ticket_function_clone_fault(
          tickets[1].sq_index, RDMA_CMQ_TEST_CLONE_GOOD
        ))
      `uvm_error("EXPIRE_SNAPSHOT_FAILURE_CLEAR",
                 "could not clear the second ticket snapshot fault")
    engine.expire(completions, status);
    expect_status("EXPIRE_SNAPSHOT_FAILURE_RETRY_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 2)
      `uvm_error("EXPIRE_SNAPSHOT_FAILURE_RETRY_OUTPUT",
                 "retry did not deliver exactly two timeout completions")
    else begin
      expect_timeout_completion("EXPIRE_SNAPSHOT_FAILURE_RETRY_0",
                                completions[0], tickets[0]);
      expect_timeout_completion("EXPIRE_SNAPSHOT_FAILURE_RETRY_1",
                                completions[1], tickets[1]);
    end
    if (engine.terminal_fifo_count() != 0 ||
        engine.diagnostic_fifo_count() != 0 ||
        engine.published_count() != 2 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 2 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 2 ||
        engine.slot_state_at(tickets[0].sq_index) !=
          CMQ_SLOT_TIMED_OUT_QUARANTINED ||
        engine.slot_state_at(tickets[1].sq_index) !=
          CMQ_SLOT_TIMED_OUT_QUARANTINED)
      `uvm_error("EXPIRE_SNAPSHOT_FAILURE_RETRY_LEDGER",
                 "successful retry did not quarantine both commands")

    engine.expire(completions, status);
    expect_status("EXPIRE_SNAPSHOT_FAILURE_ONCE_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 0)
      `uvm_error("EXPIRE_SNAPSHOT_FAILURE_ONCE",
                 "retry timeout completions were delivered more than once")
    engine.shutdown(status);
    expect_status("EXPIRE_SNAPSHOT_FAILURE_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_late_diagnostic_snapshot_failure_is_retryable 中构造或驱动“late diagnostic snapshot
  //   failure is retryable”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_late_diagnostic_snapshot_failure_is_retryable();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc request;
    rdma_cmq_ticket ticket;
    rdma_dma_mapping mapping;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_cqe;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "late_snapshot_failure_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("late_snapshot_failure_mem");
    pcie = rdma_cmq_test_pcie::type_id::create(
      "late_snapshot_failure_pcie"
    );
    trace = rdma_mock_call_trace::type_id::create(
      "late_snapshot_failure_trace"
    );
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "late_snapshot_failure_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "late_snapshot_failure_profile"
    );
    prepared_binding = make_binding("late_snapshot_failure_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("late_snapshot_failure_active",
                                  RDMA_BIND_ACTIVE);
    cmq = make_cmq("late_snapshot_failure_cmq", prepared_binding);
    prepare_active(
      "LATE_SNAPSHOT_FAILURE", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    clear_submit_observation(mem, pcie, trace);

    request = make_command(
      "late_snapshot_failure_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'hda, 10ns
    );
    engine.submit(request, ticket, status);
    expect_status("LATE_SNAPSHOT_FAILURE_SUBMIT", status, RDMA_SC_OK);
    if (ticket == null) begin
      `uvm_error("LATE_SNAPSHOT_FAILURE_SUBMIT",
                 "late diagnostic fixture returned no ticket")
      engine.shutdown(status);
      return;
    end
    mapping = engine.mapping_snapshot();
    #20ns;
    engine.expire(completions, status);
    expect_status("LATE_SNAPSHOT_FAILURE_EXPIRE", status, RDMA_SC_OK);
    if (completions.size() != 1)
      `uvm_error("LATE_SNAPSHOT_FAILURE_EXPIRE",
                 "fixture did not produce one timeout completion")
    else
      expect_timeout_completion("LATE_SNAPSHOT_FAILURE_TIMEOUT",
                                completions[0], ticket);
    if (engine.slot_state_at(ticket.sq_index) !=
          CMQ_SLOT_TIMED_OUT_QUARANTINED ||
        engine.command_registry_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.entry_registry_count() != 1)
      `uvm_error("LATE_SNAPSHOT_FAILURE_QUARANTINE",
                 "fixture did not retain quarantined late-CQE authority")

    write_profile_cqe(
      "LATE_SNAPSHOT_FAILURE_CQE", mem, mapping, profile, 0, 1'b1,
      ticket, 0, raw_cqe
    );
    if (!engine.install_slot_ticket_function_clone_fault(
          ticket.sq_index, RDMA_CMQ_TEST_CLONE_NULL
        ))
      `uvm_error("LATE_SNAPSHOT_FAILURE_INJECT",
                 "could not inject the late diagnostic ticket fault")
    rdma_cmq_clone_fault_function_handle::clear_fault_clone_calls();
    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("LATE_SNAPSHOT_FAILURE_STATUS", status,
                  RDMA_SC_INVALID_STATE);
    if (rdma_cmq_clone_fault_function_handle::fault_clone_call_count() != 1)
      `uvm_error("LATE_SNAPSHOT_FAILURE_HIT",
                 "the late diagnostic ticket fault was not exercised once")
    if (completions.size() != 0 || diagnostics.size() != 0 ||
        engine.terminal_fifo_count() != 0 ||
        engine.diagnostic_fifo_count() != 0 ||
        engine.published_count() != 1 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 1 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 1 ||
        engine.slot_state_at(ticket.sq_index) !=
          CMQ_SLOT_TIMED_OUT_QUARANTINED ||
        count_host_calls(mem, "read") != 1)
      `uvm_error("LATE_SNAPSHOT_FAILURE_ATOMIC",
                 "diagnostic snapshot failure consumed the late CQE")

    if (!engine.set_slot_ticket_function_clone_fault(
          ticket.sq_index, RDMA_CMQ_TEST_CLONE_GOOD
        ))
      `uvm_error("LATE_SNAPSHOT_FAILURE_CLEAR",
                 "could not clear the late diagnostic ticket fault")
    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("LATE_SNAPSHOT_FAILURE_RETRY_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 0 || diagnostics.size() != 1)
      `uvm_error("LATE_SNAPSHOT_FAILURE_RETRY_OUTPUT",
                 "retry did not deliver one late diagnostic")
    else
      expect_late_diagnostic("LATE_SNAPSHOT_FAILURE_RETRY_DIAG", engine,
                             diagnostics[0], ticket, raw_cqe);
    if (engine.terminal_fifo_count() != 0 ||
        engine.diagnostic_fifo_count() != 0 ||
        engine.published_count() != 1 || engine.retired_count() != 1 ||
        engine.cq_consumed_count() != 1 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0 ||
        count_host_calls(mem, "read") != 1)
      `uvm_error("LATE_SNAPSHOT_FAILURE_RETRY_LEDGER",
                 "late diagnostic retry did not consume and retire once")

    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("LATE_SNAPSHOT_FAILURE_ONCE_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 0 || diagnostics.size() != 0)
      `uvm_error("LATE_SNAPSHOT_FAILURE_ONCE",
                 "late diagnostic was delivered more than once")
    if (count_host_calls(mem, "read") != 1)
      `uvm_error("LATE_SNAPSHOT_FAILURE_ONCE_READ",
                 "formatted empty ledger did not read its current CQ slot")
    expect_poll_read_geometry("LATE_SNAPSHOT_FAILURE_ONCE_GEOMETRY",
                              mem, 1, 1);
    engine.shutdown(status);
    expect_status("LATE_SNAPSHOT_FAILURE_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_command_incarnation_exhaustion 中构造或驱动“command incarnation exhaustion”场景，并断言
  //   DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_command_incarnation_exhaustion();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc request;
    rdma_cmq_ticket first_ticket;
    rdma_cmq_ticket second_ticket;
    rdma_cmq_ticket exhausted_ticket;
    rdma_dma_mapping mapping;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_cqe;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("exhaustion_engine");
    mem = rdma_mock_host_mem::type_id::create("exhaustion_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("exhaustion_pcie");
    trace = rdma_mock_call_trace::type_id::create("exhaustion_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "exhaustion_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("exhaustion_profile");
    prepared_binding = make_binding("exhaustion_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("exhaustion_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("exhaustion_cmq", prepared_binding);
    prepare_active("EXHAUSTION", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    mapping = engine.mapping_snapshot();
    engine.seed_token_incarnation(0, {59{1'b1}});
    clear_submit_observation(mem, pcie, trace);

    request = make_command("exhaustion_skip_first", active_binding,
                           rdma_cmq_test_profile::TEST_OPCODE_A, 8'he0, 1us);
    engine.submit(request, first_ticket, status);
    expect_status("EXHAUSTION_SKIP_FIRST", status, RDMA_SC_OK);
    if (first_ticket == null || first_ticket.command_id[4:0] != 1 ||
        engine.token_incarnation_at(0) != {59{1'b1}})
      `uvm_error("EXHAUSTION_SKIP_FIRST",
                 "max-incarnation token was not permanently skipped")

    if (first_ticket != null) begin
      mem.calls.delete();
      write_profile_cqe(
        "EXHAUSTION_FIRST_CQE", mem, mapping, profile, 0, 1'b1,
        first_ticket, 0, raw_cqe
      );
      engine.poll(completions, diagnostics, status);
      expect_status("EXHAUSTION_FIRST_POLL", status, RDMA_SC_OK);
      if (completions.size() != 1 || diagnostics.size() != 0)
        `uvm_error("EXHAUSTION_FIRST_POLL",
                   "skip fixture did not complete normally")
    end

    clear_submit_observation(mem, pcie, trace);
    request = make_command("exhaustion_skip_again", active_binding,
                           rdma_cmq_test_profile::TEST_OPCODE_B, 8'he1, 1us);
    engine.submit(request, second_ticket, status);
    expect_status("EXHAUSTION_SKIP_AGAIN", status, RDMA_SC_OK);
    if (first_ticket == null || second_ticket == null ||
        second_ticket.command_id[4:0] != 1 ||
        second_ticket.command_id[63:5] <= first_ticket.command_id[63:5] ||
        engine.token_incarnation_at(0) != {59{1'b1}})
      `uvm_error("EXHAUSTION_SKIP_AGAIN",
                 "max-incarnation token became allocatable after retirement")

    engine.seed_all_token_incarnations({59{1'b1}});
    clear_submit_observation(mem, pcie, trace);
    request = make_command("exhaustion_all", active_binding,
                           rdma_cmq_test_profile::TEST_OPCODE_A, 8'he2, 1us);
    engine.submit(request, exhausted_ticket, status);
    expect_status("EXHAUSTION_ALL", status, RDMA_SC_RESOURCE_EXHAUSTED);
    if (exhausted_ticket != null)
      `uvm_error("EXHAUSTION_ALL", "exhausted submit returned a ticket")
    expect_no_submit_side_effects("EXHAUSTION_ALL_EFFECTS", mem, pcie,
                                  trace);
    if (engine.published_count() != 2 || engine.retired_count() != 1 ||
        engine.cq_consumed_count() != 1 ||
        engine.tokens_in_use_count() != 1 ||
        engine.slot_record_count() != 1 ||
        engine.command_registry_count() != 1 ||
        engine.entry_registry_count() != 1 ||
        engine.token_incarnation_at(0) != {59{1'b1}})
      `uvm_error("EXHAUSTION_ALL_LEDGER",
                 "resource exhaustion polluted committed authority")

    engine.shutdown(status);
    expect_status("EXHAUSTION_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_incarnation_survives_reprepare 中构造或驱动“incarnation survives reprepare”场景，并断言
  //   DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_incarnation_survives_reprepare();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc request;
    rdma_cmq_ticket first_ticket;
    rdma_cmq_ticket second_ticket;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("incarnation_engine");
    mem = rdma_mock_host_mem::type_id::create("incarnation_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("incarnation_pcie");
    trace = rdma_mock_call_trace::type_id::create("incarnation_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "incarnation_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "incarnation_profile"
    );
    prepared_binding = make_binding("incarnation_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("incarnation_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("incarnation_cmq", prepared_binding);
    prepare_active("INCARNATION", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    request = make_command("incarnation_first", active_binding,
                           rdma_cmq_test_profile::TEST_OPCODE_A, 8'hc0);
    engine.submit(request, first_ticket, status);
    expect_status("INCARNATION_FIRST", status, RDMA_SC_OK);
    if (first_ticket == null)
      `uvm_error("INCARNATION_FIRST", "first submit returned no ticket")

    engine.shutdown(status);
    expect_status("INCARNATION_SHUTDOWN", status, RDMA_SC_OK);
    prepared_binding = make_binding("incarnation_reprepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("incarnation_reactive", RDMA_BIND_ACTIVE);
    cmq = make_cmq("incarnation_recmq", prepared_binding);
    engine.prepare(prepared_binding, cmq, 1'b1, 20'h34567, mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("INCARNATION_REPREPARE", status, RDMA_SC_OK);
    engine.activate(active_binding, status);
    expect_status("INCARNATION_REACTIVATE", status, RDMA_SC_OK);
    clear_submit_observation(mem, pcie, trace);

    request = make_command("incarnation_second", active_binding,
                           rdma_cmq_test_profile::TEST_OPCODE_A, 8'hc1);
    engine.submit(request, second_ticket, status);
    expect_status("INCARNATION_SECOND", status, RDMA_SC_OK);
    if (first_ticket == null || second_ticket == null)
      `uvm_error("INCARNATION_MONOTONIC",
                 "same-generation lifecycle submit returned null ticket")
    else if (second_ticket.command_id == first_ticket.command_id ||
             second_ticket.command_id[4:0] !=
               first_ticket.command_id[4:0] ||
             second_ticket.command_id[63:5] <=
               first_ticket.command_id[63:5])
      `uvm_error("INCARNATION_MONOTONIC",
                 "shutdown/reprepare reused a prior full command ID")

    engine.shutdown(status);
    expect_status("INCARNATION_FINAL_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_max_dependency_id_boundary 中构造或驱动“max dependency id boundary”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_max_dependency_id_boundary();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;
    longint unsigned captured_dependency_id;

    disarm_submission_factory_faults();
    engine = rdma_cmq_engine_probe::type_id::create(
      "max_dependency_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("max_dependency_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("max_dependency_pcie");
    trace = rdma_mock_call_trace::type_id::create("max_dependency_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "max_dependency_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "max_dependency_profile"
    );
    prepared_binding = make_binding("max_dependency_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("max_dependency_active",
                                  RDMA_BIND_ACTIVE);
    cmq = make_cmq("max_dependency_cmq", prepared_binding);
    prepare_active("MAX_DEPENDENCY", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);
    engine.seed_ring_counters(64'hffff_ffff_ffff_fffe,
                              64'hffff_ffff_ffff_fffe);
    rdma_cmq_failing_dependency::arm_capture();

    requests = new[1];
    requests[0] = make_command(
      "max_dependency_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'hbe, 10us
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("MAX_DEPENDENCY_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] == null ||
        item_statuses.size() != 1)
      `uvm_error("MAX_DEPENDENCY_OUTPUT", "boundary output is invalid")
    else begin
      expect_status("MAX_DEPENDENCY_ITEM", item_statuses[0], RDMA_SC_OK);
      if (tickets[0].slot_sequence != 64'hffff_ffff_ffff_fffe ||
          tickets[0].sq_index != 30 || !tickets[0].sq_wrap)
        `uvm_error("MAX_DEPENDENCY_TICKET",
                   "maximum valid dependency boundary used the wrong slot")
    end
    if (!rdma_cmq_failing_dependency::take_captured_dependency_id(
          captured_dependency_id
        ) || captured_dependency_id != 64'hffff_ffff_ffff_ffff)
      `uvm_error("MAX_DEPENDENCY_ID",
                 "slot max-1 did not produce dependency ID max")
    if (mem.calls.size() != 1 || mem.calls[0].offset != (30 * 64) ||
        pcie.calls.size() != 3 || profile.last_final_pi != 31 ||
        !profile.last_polarity)
      `uvm_error("MAX_DEPENDENCY_TRANSPORT",
                 "maximum valid dependency boundary was not published")
    if (engine.published_count() != 64'hffff_ffff_ffff_ffff ||
        engine.retired_count() != 64'hffff_ffff_ffff_fffe ||
        engine.tokens_in_use_count() != 1 ||
        engine.slot_record_count() != 1)
      `uvm_error("MAX_DEPENDENCY_LEDGER",
                 "maximum valid dependency boundary corrupted authority")

    disarm_submission_factory_faults();
    engine.shutdown(status);
    expect_status("MAX_DEPENDENCY_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_counter_invariants_poison_before_transport 中构造或驱动“counter invariants poison
  //   before transport”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_counter_invariants_poison_before_transport();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;
    longint unsigned seeded_publish_seq;
    longint unsigned seeded_retire_seq;
    int unsigned request_count;
    string label;

    for (int unsigned invariant = 0; invariant < 3; invariant++) begin
      case (invariant)
        0: begin
          label = "COUNTER_NEXT_PUBLICATION_OVERFLOW";
          seeded_publish_seq = 64'hffff_ffff_ffff_fff0;
          seeded_retire_seq = 64'hffff_ffff_ffff_fff0;
          request_count = 32;
        end
        1: begin
          label = "COUNTER_PUBLISH_BEFORE_RETIRE";
          seeded_publish_seq = 4;
          seeded_retire_seq = 5;
          request_count = 1;
        end
        default: begin
          label = "COUNTER_OCCUPANCY_EXCEEDS_DEPTH";
          seeded_publish_seq = 33;
          seeded_retire_seq = 0;
          request_count = 1;
        end
      endcase

      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("counter_poison_engine_%0d", invariant)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("counter_poison_mem_%0d", invariant)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("counter_poison_pcie_%0d", invariant)
      );
      trace = rdma_mock_call_trace::type_id::create(
        $sformatf("counter_poison_trace_%0d", invariant)
      );
      mem.set_call_trace(trace);
      pcie.set_call_trace(trace);
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("counter_poison_scheduler_%0d", invariant)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("counter_poison_profile_%0d", invariant)
      );
      prepared_binding = make_binding(
        $sformatf("counter_poison_prepared_%0d", invariant),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("counter_poison_active_%0d", invariant),
        RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("counter_poison_cmq_%0d", invariant),
                     prepared_binding);
      prepare_active(label, engine, mem, pcie, scheduler, profile,
                     prepared_binding, active_binding, cmq, runtime_desc);
      clear_submit_observation(mem, pcie, trace);
      engine.seed_ring_counters(seeded_publish_seq, seeded_retire_seq);

      requests = new[request_count];
      foreach (requests[i])
        requests[i] = make_command(
          $sformatf("counter_poison_request_%0d_%0d", invariant, i),
          active_binding, rdma_cmq_test_profile::TEST_OPCODE_A,
          byte'(8'hc0 + i), 10us
        );
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      if (batch_status == null || batch_status.ok())
        `uvm_error("COUNTER_POISON_STATUS",
                   $sformatf("%s did not fail the batch", label))
      if (invariant == 0 &&
          (batch_status == null ||
           batch_status.message !=
             "CMQ producer sequence addition overflows"))
        `uvm_error("COUNTER_POISON_OVERFLOW_BRANCH",
                   "counter overflow did not fail at producer addition")
      if (tickets.size() != request_count ||
          item_statuses.size() != request_count)
        `uvm_error("COUNTER_POISON_ALIGNMENT",
                   $sformatf("%s outputs are misaligned", label))
      else begin
        foreach (tickets[i]) begin
          if (tickets[i] != null)
            `uvm_error("COUNTER_POISON_TICKET",
                       $sformatf("%s published ticket %0d", label, i))
          if (item_statuses[i] == null || item_statuses[i].ok())
            `uvm_error("COUNTER_POISON_ITEM_STATUS",
                       $sformatf("%s item %0d did not fail", label, i))
        end
      end
      expect_no_submit_side_effects({label, "_EFFECTS"}, mem, pcie, trace);
      if (engine.state() != RDMA_CMQ_ENGINE_POISONED ||
          engine.mapping_snapshot() == null)
        `uvm_error("COUNTER_POISON_STATE",
                   $sformatf("%s did not retain poisoned release authority",
                             label))
      if (engine.published_count() != seeded_publish_seq ||
          engine.retired_count() != seeded_retire_seq ||
          engine.tokens_in_use_count() != 0 ||
          engine.slot_record_count() != 0)
        `uvm_error("COUNTER_POISON_LEDGER",
                   $sformatf("%s changed the authority ledger", label))

      engine.shutdown(status);
      expect_status({label, "_SHUTDOWN"}, status, RDMA_SC_OK);
    end
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_poll_raw_snapshot_rejects_self_clone_mutation 中构造或驱动“poll raw snapshot
  //   rejects self clone mutation”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_poll_raw_snapshot_rejects_self_clone_mutation();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc request;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_cqe;
    rdma_status status;
    uvm_factory factory;

    engine = rdma_cmq_engine_probe::type_id::create(
      "poll_raw_snapshot_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("poll_raw_snapshot_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("poll_raw_snapshot_pcie");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "poll_raw_snapshot_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "poll_raw_snapshot_profile"
    );
    prepared_binding = make_binding(
      "poll_raw_snapshot_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "poll_raw_snapshot_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("poll_raw_snapshot_cmq", prepared_binding);
    prepare_active(
      "POLL_RAW_SNAPSHOT", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    request = make_command(
      "poll_raw_snapshot_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h51, 10us
    );
    engine.submit(request, ticket, status);
    expect_status("POLL_RAW_SNAPSHOT_SUBMIT", status, RDMA_SC_OK);
    mapping = engine.mapping_snapshot();
    write_profile_cqe(
      "POLL_RAW_SNAPSHOT_CQE", mem, mapping, profile, 0, 1'b1,
      ticket, 0, raw_cqe
    );

    factory = uvm_factory::get();
    factory.set_type_override_by_type(
      rdma_hw_image::get_type(), rdma_cmq_poll_raw_self_image::get_type(),
      1'b1
    );
    rdma_cmq_poll_raw_self_image::arm_next_raw();
    profile.mutate_raw_cqe_input = 1'b1;
    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_RAW_SNAPSHOT_STATUS", status,
                  RDMA_SC_INVALID_STATE);
    if (completions.size() != 0 || diagnostics.size() != 0 ||
        engine.cq_consumed_count() != 0 || engine.retired_count() != 0 ||
        engine.tokens_in_use_count() != 1 ||
        engine.slot_record_count() != 1 ||
        engine.command_registry_count() != 1 ||
        engine.entry_registry_count() != 1)
      `uvm_error(
        "POLL_RAW_SNAPSHOT_ATOMIC",
        "raw snapshot trust failure changed terminal authority"
      )
    rdma_cmq_poll_raw_self_image::disarm();

    profile.mutate_raw_cqe_input = 1'b0;
    rdma_cmq_poll_raw_self_image::clear_clone_calls();
    rdma_cmq_poll_raw_self_image::arm_next_raw_stateful();
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_RAW_SNAPSHOT_RETRY_STATUS", status, RDMA_SC_OK);
    if (rdma_cmq_poll_raw_self_image::clone_call_count() != 1)
      `uvm_error(
        "POLL_RAW_SNAPSHOT_RETRY_CLONES",
        $sformatf(
          "raw snapshot was cloned %0d times instead of once",
          rdma_cmq_poll_raw_self_image::clone_call_count()
        )
      )
    if (completions.size() != 1 || diagnostics.size() != 0 ||
        completions[0] == null || completions[0].raw_cqe == null ||
        !engine.probe_same_image(completions[0].raw_cqe, raw_cqe) ||
        engine.cq_consumed_count() != 1 || engine.retired_count() != 1 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error(
        "POLL_RAW_SNAPSHOT_RETRY",
        "raw snapshot retry did not deliver the original CQE atomically"
      )
    rdma_cmq_poll_raw_self_image::disarm();

    engine.shutdown(status);
    expect_status("POLL_RAW_SNAPSHOT_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_poll_payload_retained_self_clone_is_detached 中构造或驱动“poll payload retained
  //   self clone is detached”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_poll_payload_retained_self_clone_is_detached();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc request;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_cmq_self_clone_completion_payload delivered_payload;
    rdma_hw_image raw_cqe;
    rdma_status status;
    int unsigned saved_value;
    int unsigned saved_object_id;

    engine = rdma_cmq_engine_probe::type_id::create(
      "poll_payload_detachment_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("poll_payload_detachment_mem");
    pcie = rdma_cmq_test_pcie::type_id::create(
      "poll_payload_detachment_pcie"
    );
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "poll_payload_detachment_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "poll_payload_detachment_profile"
    );
    profile.use_self_clone_completion_payload = 1'b1;
    prepared_binding = make_binding(
      "poll_payload_detachment_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "poll_payload_detachment_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("poll_payload_detachment_cmq", prepared_binding);
    prepare_active(
      "POLL_PAYLOAD_DETACHMENT", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    request = make_command(
      "poll_payload_detachment_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h52, 10us
    );
    engine.submit(request, ticket, status);
    expect_status("POLL_PAYLOAD_DETACHMENT_SUBMIT", status, RDMA_SC_OK);
    mapping = engine.mapping_snapshot();
    write_profile_cqe(
      "POLL_PAYLOAD_DETACHMENT_CQE", mem, mapping, profile, 0, 1'b1,
      ticket, 0, raw_cqe
    );

    engine.poll(completions, diagnostics, status);
    expect_status("POLL_PAYLOAD_DETACHMENT_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0 ||
        !$cast(delivered_payload, completions[0].decoded_response) ||
        profile.last_completion_payload_source == null ||
        delivered_payload == profile.last_completion_payload_source ||
        delivered_payload.nested_h == null ||
        delivered_payload.nested_h ==
          profile.last_completion_payload_source.nested_h) begin
      `uvm_error(
        "POLL_PAYLOAD_DETACHMENT_OUTPUT",
        "retained self-cloning payload was not deeply detached"
      )
    end
    else begin
      saved_value = delivered_payload.value;
      saved_object_id = delivered_payload.nested_h.object_id;
      profile.last_completion_payload_source.value++;
      profile.last_completion_payload_source.nested_h.object_id++;
      if (delivered_payload.value != saved_value ||
          delivered_payload.nested_h.object_id != saved_object_id)
        `uvm_error(
          "POLL_PAYLOAD_DETACHMENT_RETAINED",
          "profile-retained payload mutation reached delivered completion"
        )
    end

    engine.shutdown(status);
    expect_status("POLL_PAYLOAD_DETACHMENT_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_poll_payload_hook_contract_failures 中构造或驱动“poll payload hook contract
  //   failures”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_poll_payload_hook_contract_failures();
    rdma_cmq_test_hook_fault_e faults[8];
    string labels[8];
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc request;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_cqe;
    rdma_status status;

    faults[0] = RDMA_CMQ_TEST_HOOK_NULL_STATUS;
    faults[1] = RDMA_CMQ_TEST_HOOK_NULL_OUTPUT;
    faults[2] = RDMA_CMQ_TEST_HOOK_WRONG_TYPE;
    faults[3] = RDMA_CMQ_TEST_HOOK_ALIASED_OUTPUT;
    faults[4] = RDMA_CMQ_TEST_HOOK_MUTATED_OUTPUT;
    faults[5] = RDMA_CMQ_TEST_HOOK_MUTATE_SOURCE;
    faults[6] = RDMA_CMQ_TEST_HOOK_STATEFUL_SAME_DRIFT;
    faults[7] = RDMA_CMQ_TEST_HOOK_STATEFUL_DETACH_DRIFT;
    labels[0] = "NULL_STATUS";
    labels[1] = "NULL_OUTPUT";
    labels[2] = "WRONG_TYPE";
    labels[3] = "ALIAS";
    labels[4] = "WRONG_VALUE";
    labels[5] = "SOURCE_MUTATION";
    labels[6] = "SAME_DRIFT";
    labels[7] = "DETACH_DRIFT";

    engine = rdma_cmq_engine_probe::type_id::create(
      "poll_payload_hook_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("poll_payload_hook_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("poll_payload_hook_pcie");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "poll_payload_hook_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "poll_payload_hook_profile"
    );
    profile.use_self_clone_completion_payload = 1'b1;
    prepared_binding = make_binding(
      "poll_payload_hook_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "poll_payload_hook_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("poll_payload_hook_cmq", prepared_binding);
    prepare_active(
      "POLL_PAYLOAD_HOOK", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    request = make_command(
      "poll_payload_hook_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h60, 10us
    );
    engine.submit(request, ticket, status);
    expect_status("POLL_PAYLOAD_HOOK_SUBMIT", status, RDMA_SC_OK);
    mapping = engine.mapping_snapshot();
    write_profile_cqe(
      "POLL_PAYLOAD_HOOK_CQE", mem, mapping, profile, 0, 1'b1,
      ticket, 0, raw_cqe
    );

    foreach (faults[i]) begin
      string label;

      label = {"POLL_PAYLOAD_HOOK_", labels[i]};
      profile.completion_payload_hook_fault = faults[i];
      profile.completion_payload_same_calls = 0;
      profile.completion_payload_detach_calls = 0;
      engine.poll(completions, diagnostics, status);
      expect_status({label, "_STATUS"}, status, RDMA_SC_INVALID_STATE);
      if (completions.size() != 0 || diagnostics.size() != 0 ||
          engine.cq_consumed_count() != 0 || engine.retired_count() != 0 ||
          engine.tokens_in_use_count() != 1 ||
          engine.slot_record_count() != 1 ||
          engine.command_registry_count() != 1 ||
          engine.entry_registry_count() != 1)
        `uvm_error(label,
                   "payload hook trust failure changed terminal authority")
    end

    profile.completion_payload_hook_fault = RDMA_CMQ_TEST_HOOK_GOOD;
    profile.completion_payload_same_calls = 0;
    profile.completion_payload_detach_calls = 0;
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_PAYLOAD_HOOK_RETRY_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0 ||
        engine.cq_consumed_count() != 1 || engine.retired_count() != 1 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error(
        "POLL_PAYLOAD_HOOK_RETRY",
        "corrected payload hook did not retry the same CQE atomically"
      )

    engine.shutdown(status);
    expect_status("POLL_PAYLOAD_HOOK_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_poll_decoded_status_contract_failures 中构造或驱动“poll decoded status contract
  //   failures”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_poll_decoded_status_contract_failures();
    rdma_cmq_test_decoded_contract_fault_e faults[7];
    rdma_cmq_test_decoded_contract_fault_e legal_faults[2];
    rdma_severity_e legal_severities[2];
    string labels[7];
    string legal_labels[2];
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc request;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_cqe;
    rdma_status status;

    faults[0] = RDMA_CMQ_TEST_DECODED_ZERO_NONOK;
    faults[1] = RDMA_CMQ_TEST_DECODED_ZERO_HARDWARE_VALID;
    faults[2] = RDMA_CMQ_TEST_DECODED_NONZERO_OK;
    faults[3] = RDMA_CMQ_TEST_DECODED_NONZERO_HARDWARE_INVALID;
    faults[4] = RDMA_CMQ_TEST_DECODED_HARDWARE_MISMATCH;
    faults[5] = RDMA_CMQ_TEST_DECODED_CATEGORY_MISMATCH;
    faults[6] = RDMA_CMQ_TEST_DECODED_SEVERITY_MISMATCH;
    labels[0] = "ZERO_NONOK";
    labels[1] = "ZERO_HARDWARE_VALID";
    labels[2] = "NONZERO_OK";
    labels[3] = "NONZERO_HARDWARE_INVALID";
    labels[4] = "HARDWARE_MISMATCH";
    labels[5] = "CATEGORY_MISMATCH";
    labels[6] = "SEVERITY_MISMATCH";
    legal_faults[0] = RDMA_CMQ_TEST_DECODED_NONZERO_WARNING;
    legal_faults[1] = RDMA_CMQ_TEST_DECODED_NONZERO_FATAL;
    legal_severities[0] = RDMA_SEVERITY_WARNING;
    legal_severities[1] = RDMA_SEVERITY_FATAL;
    legal_labels[0] = "NONZERO_WARNING";
    legal_labels[1] = "NONZERO_FATAL";

    engine = rdma_cmq_engine_probe::type_id::create(
      "poll_decoded_contract_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("poll_decoded_contract_mem");
    pcie = rdma_cmq_test_pcie::type_id::create(
      "poll_decoded_contract_pcie"
    );
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "poll_decoded_contract_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "poll_decoded_contract_profile"
    );
    prepared_binding = make_binding(
      "poll_decoded_contract_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "poll_decoded_contract_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("poll_decoded_contract_cmq", prepared_binding);
    prepare_active(
      "POLL_DECODED_CONTRACT", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    request = make_command(
      "poll_decoded_contract_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h61, 10us
    );
    engine.submit(request, ticket, status);
    expect_status("POLL_DECODED_CONTRACT_SUBMIT", status, RDMA_SC_OK);
    mapping = engine.mapping_snapshot();
    write_profile_cqe(
      "POLL_DECODED_CONTRACT_CQE", mem, mapping, profile, 0, 1'b1,
      ticket, 32'h1, raw_cqe
    );

    foreach (faults[i]) begin
      string label;

      label = {"POLL_DECODED_CONTRACT_", labels[i]};
      profile.decoded_contract_fault = faults[i];
      engine.poll(completions, diagnostics, status);
      expect_status({label, "_STATUS"}, status, RDMA_SC_CODEC_ERROR);
      if (engine.state() != RDMA_CMQ_ENGINE_POISONED ||
          completions.size() != 0 || diagnostics.size() != 1 ||
          engine.published_count() != 1 ||
          engine.cq_consumed_count() != 0 || engine.retired_count() != 0 ||
          engine.tokens_in_use_count() != 1 ||
          engine.slot_record_count() != 1 ||
          engine.command_registry_count() != 1 ||
          engine.entry_registry_count() != 1 ||
          engine.terminal_fifo_count() != 0)
        `uvm_error(
          label,
          "decoded status contract violation did not poison atomically"
        )
      if (diagnostics.size() == 1)
        expect_poison_diagnostic(
          {label, "_DIAGNOSTIC"}, engine, diagnostics[0],
          RDMA_CMQ_DIAG_MALFORMED_CQE, ticket, raw_cqe,
          active_binding, cmq
        );
      engine.shutdown(status);
      expect_status({label, "_SHUTDOWN"}, status, RDMA_SC_OK);

      if (i + 1 < $size(faults)) begin
        engine = rdma_cmq_engine_probe::type_id::create(
          $sformatf("poll_decoded_contract_engine_%0d", i + 1)
        );
        mem = rdma_mock_host_mem::type_id::create(
          $sformatf("poll_decoded_contract_mem_%0d", i + 1)
        );
        pcie = rdma_cmq_test_pcie::type_id::create(
          $sformatf("poll_decoded_contract_pcie_%0d", i + 1)
        );
        scheduler = rdma_doorbell_scheduler::type_id::create(
          $sformatf("poll_decoded_contract_scheduler_%0d", i + 1)
        );
        profile = rdma_cmq_test_profile::type_id::create(
          $sformatf("poll_decoded_contract_profile_%0d", i + 1)
        );
        prepared_binding = make_binding(
          $sformatf("poll_decoded_contract_prepared_%0d", i + 1),
          RDMA_BIND_PREPARED
        );
        active_binding = make_binding(
          $sformatf("poll_decoded_contract_active_%0d", i + 1),
          RDMA_BIND_ACTIVE
        );
        cmq = make_cmq(
          $sformatf("poll_decoded_contract_cmq_%0d", i + 1),
          prepared_binding
        );
        prepare_active(
          {label, "_NEXT"}, engine, mem, pcie, scheduler, profile,
          prepared_binding, active_binding, cmq, runtime_desc
        );
        request = make_command(
          $sformatf("poll_decoded_contract_request_%0d", i + 1),
          active_binding, rdma_cmq_test_profile::TEST_OPCODE_A,
          byte'(8'h61 + i + 1), 10us
        );
        engine.submit(request, ticket, status);
        expect_status({label, "_NEXT_SUBMIT"}, status, RDMA_SC_OK);
        mapping = engine.mapping_snapshot();
        write_profile_cqe(
          {label, "_NEXT_CQE"}, mem, mapping, profile, 0, 1'b1,
          ticket, 32'h1, raw_cqe
        );
      end
    end

    foreach (legal_faults[i]) begin
      bit legal_poll_ok;
      string label;

      label = {"POLL_DECODED_CONTRACT_", legal_labels[i]};
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("poll_legal_contract_engine_%0d", i)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("poll_legal_contract_mem_%0d", i)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("poll_legal_contract_pcie_%0d", i)
      );
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("poll_legal_contract_scheduler_%0d", i)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("poll_legal_contract_profile_%0d", i)
      );
      prepared_binding = make_binding(
        $sformatf("poll_legal_contract_prepared_%0d", i),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("poll_legal_contract_active_%0d", i), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq(
        $sformatf("poll_legal_contract_cmq_%0d", i), prepared_binding
      );
      prepare_active(
        label, engine, mem, pcie, scheduler, profile, prepared_binding,
        active_binding, cmq, runtime_desc
      );
      request = make_command(
        $sformatf("poll_decoded_contract_legal_request_%0d", i),
        active_binding, rdma_cmq_test_profile::TEST_OPCODE_A,
        byte'(8'h70 + i), 10us
      );
      engine.submit(request, ticket, status);
      expect_status({label, "_SUBMIT"}, status, RDMA_SC_OK);
      mapping = engine.mapping_snapshot();
      write_profile_cqe(
        {label, "_CQE"}, mem, mapping, profile, 0, 1'b1, ticket,
        32'h1, raw_cqe
      );

      profile.decoded_contract_fault = legal_faults[i];
      engine.poll(completions, diagnostics, status);
      legal_poll_ok = status != null && status.ok();
      expect_status({label, "_STATUS"}, status, RDMA_SC_OK);
      if (!legal_poll_ok || completions.size() != 1 ||
          diagnostics.size() != 0 || completions[0] == null ||
          completions[0].ticket == null ||
          completions[0].ticket.command_id != ticket.command_id ||
          completions[0].status == null || completions[0].status.ok() ||
          completions[0].status.category !=
            rdma_status::category_for(completions[0].status.code) ||
          !completions[0].status.hardware_code_valid ||
          completions[0].status.hardware_code != 32'h1 ||
          completions[0].status.severity != legal_severities[i] ||
          completions[0].raw_cqe == null ||
          !engine.probe_same_image(completions[0].raw_cqe, raw_cqe) ||
          engine.published_count() != 1 ||
          engine.cq_consumed_count() != 1 ||
          engine.retired_count() != 1 ||
          engine.tokens_in_use_count() != 0 ||
          engine.slot_record_count() != 0 ||
          engine.command_registry_count() != 0 ||
          engine.entry_registry_count() != 0 ||
          engine.terminal_fifo_count() != 0)
        `uvm_error(
          label,
          "legal nonzero severity did not preserve completion authority"
        )

      profile.decoded_contract_fault = RDMA_CMQ_TEST_DECODED_CONTRACT_GOOD;
      engine.shutdown(status);
      expect_status({label, "_SHUTDOWN"}, status, RDMA_SC_OK);
    end
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_poll_ticket_root_is_explicitly_constructed 中构造或驱动“poll ticket root is
  //   explicitly constructed”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_poll_ticket_root_is_explicitly_constructed();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_cqe;
    rdma_status status;

    rdma_cmq_failing_ticket::disarm();
    engine = rdma_cmq_engine_probe::type_id::create(
      "poll_explicit_ticket_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("poll_explicit_ticket_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("poll_explicit_ticket_pcie");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "poll_explicit_ticket_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "poll_explicit_ticket_profile"
    );
    prepared_binding = make_binding(
      "poll_explicit_ticket_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "poll_explicit_ticket_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("poll_explicit_ticket_cmq", prepared_binding);
    prepare_active(
      "POLL_EXPLICIT_TICKET", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    requests = new[2];
    requests[0] = make_command(
      "poll_explicit_ticket_request_0", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h70, 10us
    );
    requests[1] = make_command(
      "poll_explicit_ticket_request_1", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'h71, 10us
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("POLL_EXPLICIT_TICKET_SUBMIT", batch_status, RDMA_SC_OK);
    mapping = engine.mapping_snapshot();
    write_profile_cqe(
      "POLL_EXPLICIT_TICKET_CQE", mem, mapping, profile, 0, 1'b1,
      tickets[1], 0, raw_cqe
    );
    rdma_cmq_failing_ticket::arm();
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_EXPLICIT_TICKET_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0)
      `uvm_error("POLL_EXPLICIT_TICKET_OUTPUT",
                 "out-of-order CQE did not deliver one completion")
    if (!rdma_cmq_failing_ticket::armed())
      `uvm_error("POLL_EXPLICIT_TICKET_ROOT_CLONE",
                 "completion construction invoked the ticket root clone")
    rdma_cmq_failing_ticket::disarm();
    engine.shutdown(status);
    expect_status("POLL_EXPLICIT_TICKET_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_poll_backing_out_of_order_and_owner_wrap 中构造或驱动“poll backing out of order and
  //   owner wrap”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_poll_backing_out_of_order_and_owner_wrap();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image arrival_raw[3];
    longint unsigned arrival_ids[$];
    rdma_cmq_command_desc wrap_requests[];
    rdma_cmq_ticket wrap_tickets[];
    rdma_status wrap_item_statuses[];
    rdma_hw_image wrap_raw[];
    rdma_cmq_command_desc wrapped_request;
    rdma_cmq_ticket wrapped_ticket;
    rdma_hw_image wrapped_raw;
    rdma_status status;
    byte unsigned detached_byte;

    engine = rdma_cmq_engine_probe::type_id::create("poll_engine");
    mem = rdma_mock_host_mem::type_id::create("poll_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("poll_pcie");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "poll_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("poll_profile");
    prepared_binding = make_binding("poll_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("poll_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("poll_cmq", prepared_binding);
    prepare_active("POLL", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    mapping = engine.mapping_snapshot();
    if (mapping == null)
      `uvm_error("POLL_MAPPING", "active engine returned no mapping")

    requests = new[3];
    requests[0] = make_command(
      "poll_request_0", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h90, 10us
    );
    requests[1] = make_command(
      "poll_request_1", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'h91, 10us
    );
    requests[2] = make_command(
      "poll_request_2", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h92, 10us
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("POLL_SUBMIT_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 3 || item_statuses.size() != 3) begin
      `uvm_error("POLL_SUBMIT_ALIGNMENT", "three ticket outputs are missing")
      engine.shutdown(status);
      return;
    end
    foreach (tickets[i]) begin
      expect_status($sformatf("POLL_SUBMIT_ITEM_%0d", i),
                    item_statuses[i], RDMA_SC_OK);
      if (tickets[i] == null || tickets[i].slot_sequence != i ||
          tickets[i].sq_index != i || tickets[i].sq_wrap)
        `uvm_error("POLL_SUBMIT_TICKET",
                   $sformatf("ticket %0d has a wrong initial slot", i))
    end
    if (engine.published_count() != 3 || engine.retired_count() != 0 ||
        engine.tokens_in_use_count() != 3 ||
        engine.slot_record_count() != 3 ||
        engine.command_registry_count() != 3 ||
        engine.entry_registry_count() != 3)
      `uvm_error("POLL_SUBMIT_LEDGER", "three commands were not published")

    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_OWNER_MISMATCH_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 0 || diagnostics.size() != 0 ||
        engine.cq_consumed_count() != 0 || engine.retired_count() != 0)
      `uvm_error("POLL_OWNER_MISMATCH",
                 "owner mismatch published output or advanced a counter")
    expect_poll_read_geometry("POLL_OWNER_MISMATCH_READ", mem, 0, 1);

    mem.calls.delete();
    write_profile_cqe(
      "POLL_ARRIVAL_2", mem, mapping, profile, 0, 1'b1, tickets[2],
      0, arrival_raw[0]
    );
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_ARRIVAL_2_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0)
      `uvm_error("POLL_ARRIVAL_2_OUTPUT", "arrival 2 output is misaligned")
    else begin
      expect_polled_completion(
        "POLL_ARRIVAL_2_COMPLETION", engine, completions[0], tickets[2],
        arrival_raw[0], 1'b1, 0, RDMA_SC_OK
      );
      arrival_ids.push_back(completions[0].ticket.command_id);
      detached_byte = completions[0].raw_cqe.bytes[0];
      arrival_raw[0].bytes[0] ^= 8'hff;
      if (completions[0].raw_cqe.bytes[0] != detached_byte)
        `uvm_error("POLL_ARRIVAL_2_DETACHED",
                   "caller raw image mutation reached completion")
    end
    if (engine.cq_consumed_count() != 1 ||
        engine.retired_count() != 0 ||
        engine.tokens_in_use_count() != 2 ||
        engine.slot_record_count() != 3 ||
        engine.command_registry_count() != 2 ||
        engine.entry_registry_count() != 3)
      `uvm_error("POLL_ARRIVAL_2_PREFIX",
                 "out-of-order completion advanced retirement")
    expect_poll_read_geometry("POLL_ARRIVAL_2_READ", mem, 0, 2);

    mem.calls.delete();
    write_profile_cqe(
      "POLL_ARRIVAL_0", mem, mapping, profile, 1, 1'b1, tickets[0],
      RDMA_ECODE_EC_RCE_CQ_FULL, arrival_raw[1]
    );
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_ARRIVAL_0_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0)
      `uvm_error("POLL_ARRIVAL_0_OUTPUT", "arrival 0 output is misaligned")
    else begin
      expect_polled_completion(
        "POLL_ARRIVAL_0_COMPLETION", engine, completions[0], tickets[0],
        arrival_raw[1], 1'b1, RDMA_ECODE_EC_RCE_CQ_FULL,
        RDMA_SC_QUEUE_FULL
      );
      arrival_ids.push_back(completions[0].ticket.command_id);
    end
    if (engine.cq_consumed_count() != 2 ||
        engine.retired_count() != 1 ||
        engine.tokens_in_use_count() != 1 ||
        engine.slot_record_count() != 2 ||
        engine.command_registry_count() != 1 ||
        engine.entry_registry_count() != 2)
      `uvm_error("POLL_ARRIVAL_0_PREFIX",
                 "slot zero completion retired the wrong prefix")
    expect_poll_read_geometry("POLL_ARRIVAL_0_READ", mem, 1, 2);

    mem.calls.delete();
    write_profile_cqe(
      "POLL_ARRIVAL_1", mem, mapping, profile, 2, 1'b1, tickets[1],
      0, arrival_raw[2]
    );
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_ARRIVAL_1_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0)
      `uvm_error("POLL_ARRIVAL_1_OUTPUT", "arrival 1 output is misaligned")
    else begin
      expect_polled_completion(
        "POLL_ARRIVAL_1_COMPLETION", engine, completions[0], tickets[1],
        arrival_raw[2], 1'b1, 0, RDMA_SC_OK
      );
      arrival_ids.push_back(completions[0].ticket.command_id);
    end
    if (arrival_ids.size() != 3 ||
        arrival_ids[0] != tickets[2].command_id ||
        arrival_ids[1] != tickets[0].command_id ||
        arrival_ids[2] != tickets[1].command_id)
      `uvm_error("POLL_ARRIVAL_ORDER",
                 "completion delivery did not preserve 2,0,1 arrival")
    if (engine.cq_consumed_count() != 3 ||
        engine.retired_count() != 3 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error("POLL_ARRIVAL_1_PREFIX",
                 "completion 1 did not retire the full prefix")
    expect_poll_read_geometry("POLL_ARRIVAL_1_READ", mem, 2, 1);

    wrap_requests = new[29];
    foreach (wrap_requests[i])
      wrap_requests[i] = make_command(
        $sformatf("poll_wrap_request_%0d", i), active_binding,
        (i[0] == 1'b0) ? rdma_cmq_test_profile::TEST_OPCODE_A :
                         rdma_cmq_test_profile::TEST_OPCODE_B,
        byte'(8'ha0 + i), 10us
      );
    engine.submit_batch(wrap_requests, wrap_tickets, wrap_item_statuses,
                        batch_status);
    expect_status("POLL_WRAP_SUBMIT", batch_status, RDMA_SC_OK);
    if (wrap_tickets.size() != 29 || wrap_item_statuses.size() != 29) begin
      `uvm_error("POLL_WRAP_ALIGNMENT", "owner-wrap outputs are misaligned")
      engine.shutdown(status);
      return;
    end
    if (engine.command_registry_count() != 29 ||
        engine.entry_registry_count() != 29)
      `uvm_error("POLL_WRAP_REGISTRY",
                 "owner-wrap submission did not install both registries")
    wrap_raw = new[29];
    mem.calls.delete();
    foreach (wrap_tickets[i]) begin
      expect_status($sformatf("POLL_WRAP_ITEM_%0d", i),
                    wrap_item_statuses[i], RDMA_SC_OK);
      if (wrap_tickets[i] == null ||
          wrap_tickets[i].slot_sequence != (i + 3) ||
          wrap_tickets[i].sq_index != (i + 3) ||
          wrap_tickets[i].sq_wrap)
        `uvm_error("POLL_WRAP_TICKET",
                   $sformatf("owner-wrap ticket %0d is wrong", i))
      write_profile_cqe(
        $sformatf("POLL_WRAP_CQE_%0d", i), mem, mapping, profile,
        longint'(i + 3), 1'b1, wrap_tickets[i], 0, wrap_raw[i]
      );
    end
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_WRAP_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 29 || diagnostics.size() != 0)
      `uvm_error("POLL_WRAP_OUTPUT",
                 "poll did not drain all 29 terminal completions")
    else foreach (completions[i])
      expect_polled_completion(
        $sformatf("POLL_WRAP_COMPLETION_%0d", i), engine,
        completions[i], wrap_tickets[i], wrap_raw[i], 1'b1, 0,
        RDMA_SC_OK
      );
    expect_poll_read_geometry("POLL_WRAP_READ", mem, 3, 29);
    if (engine.cq_consumed_count() != 32 ||
        engine.retired_count() != 32 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error("POLL_WRAP_LEDGER",
                 "32 CQEs did not complete and retire exactly once")

    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_OWNER_FLIP_EMPTY_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 0 || diagnostics.size() != 0 ||
        engine.cq_consumed_count() != 32)
      `uvm_error("POLL_OWNER_FLIP_EMPTY",
                 "old owner-1 CQE was reused after owner flip")
    expect_poll_read_geometry("POLL_OWNER_FLIP_EMPTY_READ", mem, 32, 1);

    wrapped_request = make_command(
      "poll_sequence_32", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'he0, 10us
    );
    engine.submit(wrapped_request, wrapped_ticket, status);
    expect_status("POLL_SEQUENCE_32_SUBMIT", status, RDMA_SC_OK);
    if (wrapped_ticket == null || wrapped_ticket.slot_sequence != 32 ||
        wrapped_ticket.sq_index != 0 || !wrapped_ticket.sq_wrap)
      `uvm_error("POLL_SEQUENCE_32_TICKET",
                 "sequence 32 did not reuse wrapped slot zero")
    if (engine.command_registry_count() != 1 ||
        engine.entry_registry_count() != 1)
      `uvm_error("POLL_SEQUENCE_32_REGISTRY",
                 "wrapped command did not install both registries")
    mem.calls.delete();
    write_profile_cqe(
      "POLL_SEQUENCE_32_CQE", mem, mapping, profile, 32, 1'b0,
      wrapped_ticket, 0, wrapped_raw
    );
    engine.poll(completions, diagnostics, status);
    expect_status("POLL_SEQUENCE_32_STATUS", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0)
      `uvm_error("POLL_SEQUENCE_32_OUTPUT",
                 "owner-zero CQE did not produce one completion")
    else
      expect_polled_completion(
        "POLL_SEQUENCE_32_COMPLETION", engine, completions[0],
        wrapped_ticket, wrapped_raw, 1'b0, 0, RDMA_SC_OK
      );
    expect_poll_read_geometry("POLL_SEQUENCE_32_READ", mem, 32, 1);
    if (engine.cq_consumed_count() != 33 ||
        engine.retired_count() != 33 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error("POLL_SEQUENCE_32_LEDGER",
                 "owner-zero completion did not close wrapped command")

    engine.shutdown(status);
    expect_status("POLL_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_retire_then_wrap_publication 中构造或驱动“retire then wrap publication”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_retire_then_wrap_publication();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_dma_mapping mapping;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_cqe;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("wrap_engine");
    mem = rdma_mock_host_mem::type_id::create("wrap_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("wrap_pcie");
    trace = rdma_mock_call_trace::type_id::create("wrap_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create("wrap_scheduler");
    profile = rdma_cmq_test_profile::type_id::create("wrap_profile");
    prepared_binding = make_binding("wrap_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("wrap_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("wrap_cmq", prepared_binding);
    prepare_active("WRAP", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[32];
    foreach (requests[i])
      requests[i] = make_command(
        $sformatf("wrap_fill_%0d", i), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(i + 1'b1), 10us
      );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("WRAP_FILL_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 32 || item_statuses.size() != 32)
      `uvm_error("WRAP_FILL_ALIGNMENT", "fill outputs are misaligned")
    else begin
      foreach (tickets[i]) begin
        expect_status($sformatf("WRAP_FILL_ITEM_%0d", i), item_statuses[i],
                      RDMA_SC_OK);
        if (tickets[i] == null)
          `uvm_error("WRAP_FILL_TICKET",
                     $sformatf("fill ticket %0d is null", i))
      end
    end

    mapping = engine.mapping_snapshot();
    clear_submit_observation(mem, pcie, trace);
    write_profile_cqe(
      "WRAP_RETIRE_ZERO", mem, mapping, profile, 0, 1'b1, tickets[0],
      0, raw_cqe
    );
    engine.poll(completions, diagnostics, status);
    expect_status("WRAP_RETIRE_ZERO", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0)
      `uvm_error("WRAP_RETIRE_OUTPUT",
                 "real CQE did not produce one slot-zero completion")
    else
      expect_polled_completion(
        "WRAP_RETIRE_COMPLETION", engine, completions[0], tickets[0],
        raw_cqe, 1'b1, 0, RDMA_SC_OK
      );
    if (engine.published_count() != 32 || engine.retired_count() != 1 ||
        engine.tokens_in_use_count() != 31 ||
        engine.slot_record_count() != 31)
      `uvm_error("WRAP_RETIRE_LEDGER",
                 "retiring slot zero changed the wrong authority")

    clear_submit_observation(mem, pcie, trace);
    requests = new[1];
    requests[0] = make_command("wrap_sequence_32", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_B,
                               8'hf0, 10us);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("WRAP_SEQUENCE_32_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] == null ||
        item_statuses.size() != 1)
      `uvm_error("WRAP_SEQUENCE_32_OUTPUT", "wrapped output is invalid")
    else begin
      expect_status("WRAP_SEQUENCE_32_ITEM", item_statuses[0], RDMA_SC_OK);
      if (tickets[0].slot_sequence != 32 || tickets[0].sq_index != 0 ||
          !tickets[0].sq_wrap)
        `uvm_error("WRAP_SEQUENCE_32_TICKET",
                   "wrapped ticket did not reuse slot zero at sequence 32")
    end
    if (mem.calls.size() != 1 || mem.calls[0].offset != 0 ||
        mem.calls[0].data.size() != 64 ||
        mem.calls[0].data[5][1:0] != 2'b01)
      `uvm_error("WRAP_SEQUENCE_32_SQE",
                 "sequence 32 SQE did not encode valid=0/wrap=1")
    if (pcie.calls.size() != 3 ||
        pcie.calls[2].method_name != "mmio_write" ||
        pcie.calls[2].data.size() != 8 ||
        pcie.calls[2].data[0] != 8'h01 ||
        pcie.calls[2].data[1] != 8'h01 ||
        profile.last_final_pi != 1 || !profile.last_polarity)
      `uvm_error("WRAP_SEQUENCE_32_DOORBELL",
                 "sequence 32 doorbell did not encode PI=1/polarity=1")
    if (engine.published_count() != 33 || engine.retired_count() != 1 ||
        engine.tokens_in_use_count() != 32 ||
        engine.slot_record_count() != 32)
      `uvm_error("WRAP_SEQUENCE_32_LEDGER",
                 "wrapped publication did not restore full occupancy")

    engine.shutdown(status);
    expect_status("WRAP_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_full_initial_capacity_and_shutdown_reset 中构造或驱动“full initial capacity and
  //   shutdown reset”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_full_initial_capacity_and_shutdown_reset();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_mock_call_trace trace;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("capacity_engine");
    mem = rdma_mock_host_mem::type_id::create("capacity_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("capacity_pcie");
    trace = rdma_mock_call_trace::type_id::create("capacity_trace");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "capacity_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("capacity_profile");
    prepared_binding = make_binding("capacity_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("capacity_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("capacity_cmq", prepared_binding);
    prepare_active("CAPACITY", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    clear_submit_observation(mem, pcie, trace);

    requests = new[33];
    foreach (requests[i])
      requests[i] = make_command(
        $sformatf("capacity_%0d", i), active_binding,
        (i[0] == 1'b0) ? rdma_cmq_test_profile::TEST_OPCODE_A :
                         rdma_cmq_test_profile::TEST_OPCODE_B,
        byte'(i + 1'b1), 10us
      );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("CAPACITY_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 33 || item_statuses.size() != 33)
      `uvm_error("CAPACITY_ALIGNMENT", "capacity outputs misaligned")
    else begin
      for (int unsigned i = 0; i < 32; i++) begin
        expect_status($sformatf("CAPACITY_ITEM_%0d", i), item_statuses[i],
                      RDMA_SC_OK);
        if (tickets[i] == null || tickets[i].slot_sequence != i ||
            tickets[i].sq_index != i || tickets[i].sq_wrap)
          `uvm_error("CAPACITY_TICKET",
                     $sformatf("capacity ticket %0d is invalid", i))
      end
      expect_status("CAPACITY_ITEM_FULL", item_statuses[32],
                    RDMA_SC_QUEUE_FULL);
      if (tickets[32] != null)
        `uvm_error("CAPACITY_ITEM_FULL",
                   "33rd initial command incorrectly consumed a slot")
    end
    if (mem.calls.size() != 32 || pcie.calls.size() != 3 ||
        pcie.calls[2].method_name != "mmio_write" ||
        pcie.calls[2].data.size() != 8 ||
        pcie.calls[2].data[0] != 8'h00 ||
        pcie.calls[2].data[1] != 8'h01 ||
        profile.doorbell_calls != 1 || profile.last_final_pi != 0 ||
        !profile.last_polarity)
      `uvm_error("CAPACITY_DOORBELL",
                 "full 32-entry publication did not use PI 0/polarity 1")
    if (engine.published_count() != 32 ||
        engine.tokens_in_use_count() != 32 ||
        engine.slot_record_count() != 32)
      `uvm_error("CAPACITY_LEDGER", "full initial capacity was not committed")

    clear_submit_observation(mem, pcie, trace);
    requests = new[1];
    requests[0] = make_command("capacity_overflow", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'hfe);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("CAPACITY_OVERFLOW_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] != null ||
        item_statuses.size() != 1)
      `uvm_error("CAPACITY_OVERFLOW", "full-ring output invalid")
    else
      expect_status("CAPACITY_OVERFLOW_ITEM", item_statuses[0],
                    RDMA_SC_QUEUE_FULL);
    expect_no_submit_side_effects("CAPACITY_OVERFLOW_EFFECTS", mem, pcie,
                                  trace);

    engine.shutdown(status);
    expect_status("CAPACITY_SHUTDOWN", status, RDMA_SC_OK);
    if (engine.published_count() != 0 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0 ||
        engine.outstanding_count() != 0 ||
        engine.quarantine_count() != 0 ||
        engine.mapping_snapshot() != null)
      `uvm_error("CAPACITY_SHUTDOWN_RESET",
                 "shutdown did not clear slots, tokens, and counters")

    prepared_binding = make_binding("capacity_reprepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("capacity_reactive", RDMA_BIND_ACTIVE);
    cmq = make_cmq("capacity_recmq", prepared_binding);
    profile.sqe_endian = RDMA_ENDIAN_LITTLE;
    profile.sqe_hardware_version = 13;
    engine.prepare(prepared_binding, cmq, 1'b1, 20'h34567, mem,
                   scheduler, profile, runtime_desc, status);
    expect_status("CAPACITY_REPREPARE", status, RDMA_SC_OK);
    engine.activate(active_binding, status);
    expect_status("CAPACITY_REACTIVATE", status, RDMA_SC_OK);
    clear_submit_observation(mem, pcie, trace);
    requests[0] = make_command("capacity_reuse", active_binding,
                               rdma_cmq_test_profile::TEST_OPCODE_A, 8'h77);
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("CAPACITY_REUSE_BATCH", batch_status, RDMA_SC_OK);
    if (tickets.size() != 1 || tickets[0] == null ||
        tickets[0].slot_sequence != 0 || tickets[0].sq_index != 0 ||
        tickets[0].command_id != 64'd64)
      `uvm_error("CAPACITY_REUSE",
                 "new prepare reset a monotonic command incarnation")

    engine.shutdown(status);
    expect_status("CAPACITY_FINAL_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_retirement_preflight_poison_atomicity 中构造或驱动“retirement preflight poison
  //   atomicity”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_retirement_preflight_poison_atomicity();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc request;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_cmq_diagnostic snapshot;
    rdma_hw_image raw_cqe;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create(
      "retirement_preflight_engine"
    );
    mem = rdma_mock_host_mem::type_id::create(
      "retirement_preflight_mem"
    );
    pcie = rdma_cmq_test_pcie::type_id::create(
      "retirement_preflight_pcie"
    );
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "retirement_preflight_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "retirement_preflight_profile"
    );
    prepared_binding = make_binding(
      "retirement_preflight_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "retirement_preflight_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("retirement_preflight_cmq", prepared_binding);
    prepare_active(
      "RETIREMENT_PREFLIGHT", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    request = make_command(
      "retirement_preflight_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'ha5, 10us
    );
    engine.submit(request, ticket, status);
    expect_status("RETIREMENT_PREFLIGHT_SUBMIT", status, RDMA_SC_OK);
    if (ticket == null ||
        !engine.tamper_slot_retirement_incarnation(ticket.sq_index)) begin
      `uvm_error("RETIREMENT_PREFLIGHT_SETUP",
                 "could not install a self-consistent stale incarnation")
      engine.shutdown(status);
      return;
    end
    // Keep the caller's detached expected ticket aligned with the internal
    // self-consistent incarnation.  Both still disagree with retire_seq=0.
    ticket.slot_sequence += 32;
    ticket.sq_wrap = !ticket.sq_wrap;
    mapping = engine.mapping_snapshot();
    write_profile_cqe(
      "RETIREMENT_PREFLIGHT_CQE", mem, mapping, profile, 0, 1'b1,
      ticket, 0, raw_cqe
    );

    engine.poll(completions, diagnostics, status);
    expect_status("RETIREMENT_PREFLIGHT_POLL", status,
                  RDMA_SC_CODEC_ERROR);
    if (engine.state() != RDMA_CMQ_ENGINE_POISONED ||
        completions.size() != 0 || diagnostics.size() != 1)
      `uvm_error(
        "RETIREMENT_PREFLIGHT_OUTPUT",
        "retirement failure committed output before poisoning"
      )
    else
      expect_poison_diagnostic(
        "RETIREMENT_PREFLIGHT_DIAGNOSTIC", engine, diagnostics[0],
        RDMA_CMQ_DIAG_POISON, null, raw_cqe, active_binding, cmq
      );
    snapshot = engine.last_poison_snapshot();
    expect_poison_diagnostic(
      "RETIREMENT_PREFLIGHT_SNAPSHOT", engine, snapshot,
      RDMA_CMQ_DIAG_POISON, null, raw_cqe, active_binding, cmq
    );
    if (engine.published_count() != 1 ||
        engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0 ||
        engine.tokens_in_use_count() != 1 ||
        engine.slot_record_count() != 1 ||
        engine.command_registry_count() != 1 ||
        engine.entry_registry_count() != 1 ||
        engine.terminal_fifo_count() != 0 ||
        engine.diagnostic_fifo_count() != 0 ||
        engine.slot_state_at(ticket.sq_index) != CMQ_SLOT_PUBLISHED)
      `uvm_error(
        "RETIREMENT_PREFLIGHT_ATOMIC",
        "retirement poison consumed or changed command authority"
      )

    engine.shutdown(status);
    expect_status("RETIREMENT_PREFLIGHT_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_cqe_poison_isolation_and_snapshot_detachment 中构造或驱动“cqe poison isolation and
  //   snapshot detachment”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_cqe_poison_isolation_and_snapshot_detachment();
    rdma_cmq_test_poison_fault_e faults[7];
    rdma_cmq_diagnostic_kind_e kinds[7];
    bit trusted_ticket[7];
    string labels[7];

    faults[0] = RDMA_CMQ_TEST_POISON_RESERVED_BIT;
    faults[1] = RDMA_CMQ_TEST_POISON_UNSUPPORTED_OPCODE;
    faults[2] = RDMA_CMQ_TEST_POISON_OPCODE_MISMATCH;
    faults[3] = RDMA_CMQ_TEST_POISON_UNKNOWN_ENTRY;
    faults[4] = RDMA_CMQ_TEST_POISON_NULL_DECODED;
    faults[5] = RDMA_CMQ_TEST_POISON_NULL_COMMAND_STATUS;
    faults[6] = RDMA_CMQ_TEST_POISON_SLOT_INCARNATION;
    kinds[0] = RDMA_CMQ_DIAG_MALFORMED_CQE;
    kinds[1] = RDMA_CMQ_DIAG_MALFORMED_CQE;
    kinds[2] = RDMA_CMQ_DIAG_MALFORMED_CQE;
    kinds[3] = RDMA_CMQ_DIAG_UNKNOWN_CQE;
    kinds[4] = RDMA_CMQ_DIAG_MALFORMED_CQE;
    kinds[5] = RDMA_CMQ_DIAG_MALFORMED_CQE;
    kinds[6] = RDMA_CMQ_DIAG_POISON;
    trusted_ticket[0] = 1'b0;
    trusted_ticket[1] = 1'b0;
    trusted_ticket[2] = 1'b1;
    trusted_ticket[3] = 1'b0;
    trusted_ticket[4] = 1'b0;
    trusted_ticket[5] = 1'b1;
    trusted_ticket[6] = 1'b0;
    labels[0] = "POISON_RESERVED_BIT";
    labels[1] = "POISON_UNSUPPORTED_OPCODE";
    labels[2] = "POISON_OPCODE_MISMATCH";
    labels[3] = "POISON_UNKNOWN_ENTRY";
    labels[4] = "POISON_NULL_DECODED";
    labels[5] = "POISON_NULL_COMMAND_STATUS";
    // This is deliberately a post-read entry/slot incarnation mismatch.
    // Pre-read counter invariants have no real CQE evidence and remain the
    // separately tested submission guard rather than manufacturing raw data.
    labels[6] = "POISON_POST_READ_SLOT_INCARNATION";

    foreach (faults[i]) begin
      rdma_cmq_engine_probe engine;
      rdma_mock_host_mem mem;
      rdma_cmq_test_pcie pcie;
      rdma_doorbell_scheduler scheduler;
      rdma_cmq_test_profile profile;
      rdma_function_binding prepared_binding;
      rdma_function_binding active_binding;
      rdma_cmq cmq;
      rdma_cmq_runtime_desc runtime_desc;
      rdma_dma_mapping mapping;
      rdma_cmq_command_desc request;
      rdma_cmq_ticket ticket;
      rdma_cmq_ticket rejected_ticket;
      rdma_cmq_completion completions[$];
      rdma_cmq_diagnostic diagnostics[$];
      rdma_cmq_diagnostic first_snapshot;
      rdma_cmq_diagnostic second_snapshot;
      rdma_cmq_diagnostic third_snapshot;
      rdma_hw_image raw_cqe;
      rdma_status status;
      longint unsigned original_command_id;
      byte unsigned saved_raw_byte;
      string label;

      label = labels[i];
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("poison_engine_%0d", i)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("poison_mem_%0d", i)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("poison_pcie_%0d", i)
      );
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("poison_scheduler_%0d", i)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("poison_profile_%0d", i)
      );
      prepared_binding = make_binding(
        $sformatf("poison_prepared_%0d", i), RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("poison_active_%0d", i), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq($sformatf("poison_cmq_%0d", i), prepared_binding);
      prepare_active(label, engine, mem, pcie, scheduler, profile,
                     prepared_binding, active_binding, cmq, runtime_desc);
      request = make_command(
        $sformatf("poison_request_%0d", i), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hd0 + i), 10us
      );
      engine.submit(request, ticket, status);
      expect_status({label, "_SUBMIT"}, status, RDMA_SC_OK);
      if (ticket == null) begin
        `uvm_error(label, "poison setup returned no ticket")
        engine.shutdown(status);
        continue;
      end
      original_command_id = ticket.command_id;
      mapping = engine.mapping_snapshot();
      write_profile_cqe(
        {label, "_CQE"}, mem, mapping, profile, 0, 1'b1, ticket, 0,
        raw_cqe
      );
      case (faults[i])
        RDMA_CMQ_TEST_POISON_RESERVED_BIT:
          raw_cqe.bytes[0] |= 8'h40;
        RDMA_CMQ_TEST_POISON_UNSUPPORTED_OPCODE:
          raw_cqe.bytes[3] = 8'hfe;
        RDMA_CMQ_TEST_POISON_OPCODE_MISMATCH:
          raw_cqe.bytes[3] =
            rdma_cmq_test_profile::TEST_OPCODE_B[7:0];
        RDMA_CMQ_TEST_POISON_UNKNOWN_ENTRY:
          raw_cqe.bytes[2] = {2'b00, ticket.sq_wrap, 5'h01};
        RDMA_CMQ_TEST_POISON_NULL_DECODED:
          profile.return_null_decoded = 1'b1;
        RDMA_CMQ_TEST_POISON_NULL_COMMAND_STATUS:
          profile.return_null_command_status = 1'b1;
        RDMA_CMQ_TEST_POISON_SLOT_INCARNATION:
          if (!engine.tamper_slot_incarnation(ticket.sq_index))
            `uvm_error(label, "could not tamper the slot incarnation")
        default: begin
        end
      endcase
      overwrite_profile_cqe(label, mem, mapping, 0, raw_cqe);

      engine.poll(completions, diagnostics, status);
      expect_status({label, "_POLL_STATUS"}, status, RDMA_SC_CODEC_ERROR);
      if (engine.state() != RDMA_CMQ_ENGINE_POISONED ||
          completions.size() != 0 || diagnostics.size() != 1)
        `uvm_error(label,
                   "malformed CQE did not stop at one poison diagnostic")
      else
        expect_poison_diagnostic(
          {label, "_DIAGNOSTIC"}, engine, diagnostics[0], kinds[i],
          trusted_ticket[i] ? ticket : null, raw_cqe, active_binding, cmq
        );
      if (engine.published_count() != 1 ||
          engine.retired_count() != 0 ||
          engine.cq_consumed_count() != 0 ||
          engine.tokens_in_use_count() != 1 ||
          engine.slot_record_count() != 1 ||
          engine.command_registry_count() != 1 ||
          engine.entry_registry_count() != 1 ||
          engine.terminal_fifo_count() != 0 ||
          engine.slot_state_at(ticket.sq_index) != CMQ_SLOT_PUBLISHED ||
          engine.slot_ticket_command_id(ticket.sq_index) !=
            original_command_id)
        `uvm_error(label,
                   "poison consumed, completed, or recycled the bad slot")

      first_snapshot = engine.last_poison_snapshot();
      expect_poison_diagnostic(
        {label, "_FIRST_SNAPSHOT"}, engine, first_snapshot, kinds[i],
        trusted_ticket[i] ? ticket : null, raw_cqe, active_binding, cmq
      );
      if (diagnostics.size() == 1 && first_snapshot != null) begin
        if (first_snapshot == diagnostics[0] ||
            first_snapshot.status == diagnostics[0].status ||
            first_snapshot.raw_cqe == diagnostics[0].raw_cqe ||
            (trusted_ticket[i] &&
             first_snapshot.ticket == diagnostics[0].ticket))
          `uvm_error(label,
                     "diagnostic output aliases last-poison authority")
        diagnostics[0].status.message = "caller-mutated diagnostic";
        diagnostics[0].raw_cqe.bytes[0] ^= 8'hff;
        if (diagnostics[0].ticket != null)
          diagnostics[0].ticket.command_id++;
      end
      second_snapshot = engine.last_poison_snapshot();
      expect_poison_diagnostic(
        {label, "_SECOND_SNAPSHOT"}, engine, second_snapshot, kinds[i],
        trusted_ticket[i] ? ticket : null, raw_cqe, active_binding, cmq
      );
      if (first_snapshot == null || second_snapshot == null ||
          first_snapshot == second_snapshot ||
          first_snapshot.status == second_snapshot.status ||
          first_snapshot.raw_cqe == second_snapshot.raw_cqe ||
          (trusted_ticket[i] &&
           first_snapshot.ticket == second_snapshot.ticket))
        `uvm_error(label, "last_poison_snapshot did not detach each query")
      if (first_snapshot != null && first_snapshot.raw_cqe != null &&
          first_snapshot.status != null) begin
        saved_raw_byte = raw_cqe.bytes[0];
        first_snapshot.raw_cqe.bytes[0] ^= 8'hff;
        first_snapshot.status.message = "caller-mutated snapshot";
        if (first_snapshot.ticket != null)
          first_snapshot.ticket.command_id++;
        third_snapshot = engine.last_poison_snapshot();
        expect_poison_diagnostic(
          {label, "_THIRD_SNAPSHOT"}, engine, third_snapshot, kinds[i],
          trusted_ticket[i] ? ticket : null, raw_cqe, active_binding, cmq
        );
        if (third_snapshot != null && third_snapshot.raw_cqe != null &&
            third_snapshot.raw_cqe.bytes[0] != saved_raw_byte)
          `uvm_error(label, "snapshot mutation reached engine authority")
      end

      request = make_command(
        $sformatf("poison_rejected_request_%0d", i), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'he0 + i), 10us
      );
      engine.submit(request, rejected_ticket, status);
      if (status == null || status.ok() || rejected_ticket != null)
        `uvm_error(label, "poisoned engine accepted a later submit")
      if (i == 0 && $time < ticket.absolute_deadline)
        #(ticket.absolute_deadline - $time);
      engine.poll(completions, diagnostics, status);
      if (status == null || status.ok() || completions.size() != 0 ||
          diagnostics.size() != 0)
        `uvm_error(label, "poisoned engine accepted a later poll")
      engine.expire(completions, status);
      if (status == null || status.ok() || completions.size() != 0)
        `uvm_error(label, "poisoned engine accepted a later expire")
      if (engine.published_count() != 1 ||
          engine.retired_count() != 0 ||
          engine.cq_consumed_count() != 0 ||
          engine.tokens_in_use_count() != 1 ||
          engine.slot_record_count() != 1 ||
          engine.command_registry_count() != 1 ||
          engine.entry_registry_count() != 1 ||
          engine.terminal_fifo_count() != 0 ||
          engine.diagnostic_fifo_count() != 0)
        `uvm_error(label, "post-poison rejection changed ring authority")

      engine.shutdown(status);
      expect_status({label, "_SHUTDOWN"}, status, RDMA_SC_OK);
    end

    begin
      rdma_cmq_engine_probe engine;
      rdma_mock_host_mem mem;
      rdma_cmq_test_pcie pcie;
      rdma_doorbell_scheduler scheduler;
      rdma_cmq_test_profile profile;
      rdma_function_binding prepared_binding;
      rdma_function_binding active_binding;
      rdma_cmq cmq;
      rdma_cmq_runtime_desc runtime_desc;
      rdma_dma_mapping mapping;
      rdma_cmq_command_desc request;
      rdma_cmq_ticket ticket;
      rdma_cmq_completion completions[$];
      rdma_cmq_diagnostic diagnostics[$];
      rdma_hw_image raw_cqe;
      rdma_status status;

      engine = rdma_cmq_engine_probe::type_id::create(
        "poison_owner_mismatch_engine"
      );
      mem = rdma_mock_host_mem::type_id::create(
        "poison_owner_mismatch_mem"
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        "poison_owner_mismatch_pcie"
      );
      scheduler = rdma_doorbell_scheduler::type_id::create(
        "poison_owner_mismatch_scheduler"
      );
      profile = rdma_cmq_test_profile::type_id::create(
        "poison_owner_mismatch_profile"
      );
      prepared_binding = make_binding(
        "poison_owner_mismatch_prepared", RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        "poison_owner_mismatch_active", RDMA_BIND_ACTIVE
      );
      cmq = make_cmq("poison_owner_mismatch_cmq", prepared_binding);
      prepare_active(
        "POISON_OWNER_MISMATCH", engine, mem, pcie, scheduler, profile,
        prepared_binding, active_binding, cmq, runtime_desc
      );
      request = make_command(
        "poison_owner_mismatch_request", active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, 8'hf0, 10us
      );
      engine.submit(request, ticket, status);
      expect_status("POISON_OWNER_MISMATCH_SUBMIT", status, RDMA_SC_OK);
      mapping = engine.mapping_snapshot();
      write_profile_cqe(
        "POISON_OWNER_MISMATCH_CQE", mem, mapping, profile, 0, 1'b0,
        ticket, 0, raw_cqe
      );
      raw_cqe.bytes[0] |= 8'h40;
      raw_cqe.bytes[3] = 8'hfe;
      overwrite_profile_cqe(
        "POISON_OWNER_MISMATCH", mem, mapping, 0, raw_cqe
      );
      engine.poll(completions, diagnostics, status);
      expect_status("POISON_OWNER_MISMATCH_POLL", status, RDMA_SC_OK);
      if (engine.state() != RDMA_CMQ_ENGINE_ACTIVE ||
          completions.size() != 0 || diagnostics.size() != 0 ||
          engine.last_poison_snapshot() != null ||
          engine.cq_consumed_count() != 0 ||
          engine.tokens_in_use_count() != 1 ||
          engine.slot_record_count() != 1)
        `uvm_error(
          "POISON_OWNER_MISMATCH",
          "stale-owner garbage was inspected or poisoned the engine"
        )
      engine.shutdown(status);
      expect_status("POISON_OWNER_MISMATCH_SHUTDOWN", status, RDMA_SC_OK);
    end
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_poison_shutdown_release_retry_preserves_snapshot 中构造或驱动“poison shutdown
  //   release retry preserves snapshot”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_poison_shutdown_release_retry_preserves_snapshot();
    string labels[2];

    labels[0] = "POISON_SHUTDOWN_NULL_RELEASE";
    labels[1] = "POISON_SHUTDOWN_FAILED_RELEASE";
    for (int unsigned mode = 0; mode < 2; mode++) begin
      rdma_cmq_engine_probe engine;
      rdma_mock_host_mem mem;
      rdma_cmq_test_pcie pcie;
      rdma_doorbell_scheduler scheduler;
      rdma_cmq_test_profile profile;
      rdma_function_binding prepared_binding;
      rdma_function_binding active_binding;
      rdma_cmq cmq;
      rdma_cmq_runtime_desc runtime_desc;
      rdma_dma_mapping mapping;
      rdma_dma_mapping retained_mapping;
      rdma_mock_dma_mapping retained_mock;
      rdma_cmq_command_desc request;
      rdma_cmq_ticket ticket;
      rdma_cmq_completion completions[$];
      rdma_cmq_diagnostic diagnostics[$];
      rdma_cmq_diagnostic before_snapshot;
      rdma_cmq_diagnostic after_snapshot;
      rdma_cmq_diagnostic retry_snapshot;
      rdma_hw_image raw_cqe;
      rdma_status status;
      string label;

      label = labels[mode];
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("poison_shutdown_engine_%0d", mode)
      );
      if (mode == 0)
        mem = rdma_cmq_null_release_once_mem::type_id::create(
          "poison_shutdown_null_mem"
        );
      else
        mem = rdma_mock_host_mem::type_id::create(
          "poison_shutdown_failed_mem"
        );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("poison_shutdown_pcie_%0d", mode)
      );
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("poison_shutdown_scheduler_%0d", mode)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("poison_shutdown_profile_%0d", mode)
      );
      prepared_binding = make_binding(
        $sformatf("poison_shutdown_prepared_%0d", mode),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("poison_shutdown_active_%0d", mode), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq(
        $sformatf("poison_shutdown_cmq_%0d", mode), prepared_binding
      );
      prepare_active(
        label, engine, mem, pcie, scheduler, profile, prepared_binding,
        active_binding, cmq, runtime_desc
      );
      request = make_command(
        $sformatf("poison_shutdown_request_%0d", mode), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hb0 + mode), 10us
      );
      engine.submit(request, ticket, status);
      expect_status({label, "_SUBMIT"}, status, RDMA_SC_OK);
      mapping = engine.mapping_snapshot();
      write_profile_cqe(
        {label, "_CQE"}, mem, mapping, profile, 0, 1'b1, ticket, 0,
        raw_cqe
      );
      raw_cqe.bytes[3] = rdma_cmq_test_profile::TEST_OPCODE_B[7:0];
      overwrite_profile_cqe(label, mem, mapping, 0, raw_cqe);
      engine.poll(completions, diagnostics, status);
      expect_status({label, "_POLL"}, status, RDMA_SC_CODEC_ERROR);
      if (completions.size() != 0 || diagnostics.size() != 1)
        `uvm_error(label, "poison setup did not return one diagnostic")
      before_snapshot = engine.last_poison_snapshot();
      expect_poison_diagnostic(
        {label, "_BEFORE"}, engine, before_snapshot,
        RDMA_CMQ_DIAG_MALFORMED_CQE, ticket, raw_cqe, active_binding, cmq
      );
      if (before_snapshot != null) begin
        before_snapshot.status.message = "caller-mutated before shutdown";
        before_snapshot.raw_cqe.bytes[0] ^= 8'hff;
        before_snapshot.ticket.command_id++;
        before_snapshot.ticket.function_h.object_id++;
        before_snapshot.ticket.cmq_h.object_id++;
        before_snapshot.ticket.opcode_key.opcode++;
      end
      if (mode == 1)
        expect_status(
          {label, "_ARM"},
          mem.fail_next(
            "release",
            rdma_status::make(
              RDMA_SC_UNKNOWN_HW_ERROR,
              "injected poisoned shutdown release failure"
            )
          ),
          RDMA_SC_OK
        );

      engine.shutdown(status);
      expect_status(
        {label, "_FIRST_SHUTDOWN"}, status,
        (mode == 0) ? RDMA_SC_INVALID_STATE : RDMA_SC_UNKNOWN_HW_ERROR
      );
      retained_mapping = engine.mapping_snapshot();
      after_snapshot = engine.last_poison_snapshot();
      expect_poison_diagnostic(
        {label, "_AFTER"}, engine, after_snapshot,
        RDMA_CMQ_DIAG_MALFORMED_CQE, ticket, raw_cqe, active_binding, cmq
      );
      if (engine.state() != RDMA_CMQ_ENGINE_POISONED ||
          !engine.retry_only_poisoned() || retained_mapping == null ||
          count_host_calls(mem, "release") != 1 ||
          mem.regions.size() != 1 || mem.regions[0].mapping == null ||
          mem.regions[0].mapping.state != RDMA_MAPPING_ACTIVE)
        `uvm_error(label, "failed shutdown lost retry authority")
      if (!$cast(retained_mock, retained_mapping))
        `uvm_error(label, "failed shutdown lost mapping identity")
      if (before_snapshot == null || after_snapshot == null ||
          before_snapshot == after_snapshot ||
          before_snapshot.status == after_snapshot.status ||
          before_snapshot.raw_cqe == after_snapshot.raw_cqe ||
          before_snapshot.ticket == after_snapshot.ticket ||
          before_snapshot.ticket.function_h ==
            after_snapshot.ticket.function_h ||
          before_snapshot.ticket.cmq_h == after_snapshot.ticket.cmq_h ||
          before_snapshot.ticket.opcode_key ==
            after_snapshot.ticket.opcode_key)
        `uvm_error(label, "failed shutdown snapshot aliases caller state")
      if (after_snapshot != null) begin
        after_snapshot.raw_cqe.bytes[1] ^= 8'hff;
        after_snapshot.ticket.command_id++;
      end
      retry_snapshot = engine.last_poison_snapshot();
      expect_poison_diagnostic(
        {label, "_RETRY_SNAPSHOT"}, engine, retry_snapshot,
        RDMA_CMQ_DIAG_MALFORMED_CQE, ticket, raw_cqe, active_binding, cmq
      );

      engine.shutdown(status);
      expect_status({label, "_RETRY_SHUTDOWN"}, status, RDMA_SC_OK);
      expect_unconfigured({label, "_RETRY_STATE"}, engine);
      if (engine.last_poison_snapshot() != null ||
          count_host_calls(mem, "release") != 2 ||
          mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
        `uvm_error(label, "successful retry did not clear poison authority")
      expect_release_retry_identity(label, mem, retained_mock);
    end
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_wait_rejects_x_deadline_without_side_effects 中构造或驱动“wait rejects x deadline
  //   without side effects”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_wait_rejects_x_deadline_without_side_effects();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc request;
    rdma_cmq_ticket ticket;
    rdma_cmq_ticket caller_ticket;
    rdma_cmq_completion completion;
    rdma_hw_image raw_cqe;
    rdma_status status;
    time before_wait;
    longint unsigned before_publish;
    longint unsigned before_retire;
    longint unsigned before_consume;
    int unsigned before_slots;
    int unsigned before_tokens;
    int unsigned before_commands;
    int unsigned before_entries;

    engine = rdma_cmq_engine_probe::type_id::create(
      "wait_x_deadline_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("wait_x_deadline_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("wait_x_deadline_pcie");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "wait_x_deadline_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "wait_x_deadline_profile"
    );
    prepared_binding = make_binding(
      "wait_x_deadline_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "wait_x_deadline_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("wait_x_deadline_cmq", prepared_binding);
    prepare_active(
      "WAIT_X_DEADLINE", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    request = make_command(
      "wait_x_deadline_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'hc1, 10us
    );
    engine.submit(request, ticket, status);
    expect_status("WAIT_X_DEADLINE_SUBMIT", status, RDMA_SC_OK);
    mapping = engine.mapping_snapshot();
    write_profile_cqe(
      "WAIT_X_DEADLINE_CQE", mem, mapping, profile, 0, 1'b1,
      ticket, 0, raw_cqe
    );
    caller_ticket = rdma_cmq_ticket::type_id::create(
      "wait_x_deadline_caller_ticket"
    );
    caller_ticket.copy(ticket);
    caller_ticket.absolute_deadline = 'x;
    before_wait = $time;
    before_publish = engine.published_count();
    before_retire = engine.retired_count();
    before_consume = engine.cq_consumed_count();
    before_slots = engine.slot_record_count();
    before_tokens = engine.tokens_in_use_count();
    before_commands = engine.command_registry_count();
    before_entries = engine.entry_registry_count();
    mem.calls.delete();

    engine.wait_for(caller_ticket, completion, status);
    expect_status("WAIT_X_DEADLINE_STATUS", status,
                  RDMA_SC_INVALID_ARGUMENT);
    if (status == null || status.message != "CMQ wait ticket is invalid")
      `uvm_error("WAIT_X_DEADLINE_EXPLICIT",
                 "X deadline was not rejected by public ticket validation")
    if (completion != null || $time != before_wait ||
        count_host_calls(mem, "read") != 0 ||
        engine.state() != RDMA_CMQ_ENGINE_ACTIVE ||
        engine.published_count() != before_publish ||
        engine.retired_count() != before_retire ||
        engine.cq_consumed_count() != before_consume ||
        engine.slot_record_count() != before_slots ||
        engine.tokens_in_use_count() != before_tokens ||
        engine.command_registry_count() != before_commands ||
        engine.entry_registry_count() != before_entries ||
        engine.terminal_fifo_count() != 0 ||
        engine.diagnostic_fifo_count() != 0)
      `uvm_error("WAIT_X_DEADLINE_ATOMICITY",
                 "X deadline wait read, advanced time, or changed state")
    engine.shutdown(status);
    expect_status("WAIT_X_DEADLINE_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_wait_poison_lifecycle_boundaries 中构造或驱动“wait poison lifecycle
  //   boundaries”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_wait_poison_lifecycle_boundaries();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_cmq_completion completion;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_cmq_diagnostic snapshot;
    rdma_hw_image raw_good;
    rdma_hw_image raw_poison;
    rdma_status status;
    longint unsigned before_publish;
    longint unsigned before_retire;
    longint unsigned before_consume;
    int unsigned before_slots;
    int unsigned before_tokens;
    int unsigned before_commands;
    int unsigned before_entries;
    int unsigned normal_count;
    int unsigned cancel_count;

    engine = rdma_cmq_engine_probe::type_id::create(
      "wait_poison_lifecycle_engine"
    );
    mem = rdma_mock_host_mem::type_id::create(
      "wait_poison_lifecycle_mem"
    );
    pcie = rdma_cmq_test_pcie::type_id::create(
      "wait_poison_lifecycle_pcie"
    );
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "wait_poison_lifecycle_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "wait_poison_lifecycle_profile"
    );
    prepared_binding = make_binding(
      "wait_poison_lifecycle_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "wait_poison_lifecycle_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("wait_poison_lifecycle_cmq", prepared_binding);
    prepare_active(
      "WAIT_POISON_LIFECYCLE", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    requests = new[2];
    requests[0] = make_command(
      "wait_poison_normal_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'hc2, 10us
    );
    requests[1] = make_command(
      "wait_poison_target_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'hc3, 10us
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("WAIT_POISON_SUBMIT", batch_status, RDMA_SC_OK);
    mapping = engine.mapping_snapshot();
    write_profile_cqe(
      "WAIT_POISON_GOOD_CQE", mem, mapping, profile, 0, 1'b1,
      tickets[0], 0, raw_good
    );
    write_profile_cqe(
      "WAIT_POISON_BAD_CQE", mem, mapping, profile, 1, 1'b1,
      tickets[1], 0, raw_poison
    );
    raw_poison.bytes[3] =
      rdma_cmq_test_profile::TEST_OPCODE_B[7:0];
    overwrite_profile_cqe(
      "WAIT_POISON_BAD_CQE", mem, mapping, 1, raw_poison
    );
    mem.calls.delete();

    engine.wait_for(tickets[1], completion, status);
    expect_status("WAIT_POISON_WAIT", status, RDMA_SC_CODEC_ERROR);
    if (completion != null ||
        engine.state() != RDMA_CMQ_ENGINE_POISONED ||
        engine.terminal_fifo_count() != 1 ||
        engine.diagnostic_fifo_count() != 1 ||
        count_host_calls(mem, "read") != 2)
      `uvm_error("WAIT_POISON_SETUP",
                 "wait_for did not preserve queued completion and poison")
    snapshot = engine.last_poison_snapshot();
    if (snapshot == null)
      `uvm_error("WAIT_POISON_SNAPSHOT", "wait poison lost its snapshot")

    before_publish = engine.published_count();
    before_retire = engine.retired_count();
    before_consume = engine.cq_consumed_count();
    before_slots = engine.slot_record_count();
    before_tokens = engine.tokens_in_use_count();
    before_commands = engine.command_registry_count();
    before_entries = engine.entry_registry_count();
    engine.cancel_generation(
      active_binding.generation, completions, status
    );
    expect_status("WAIT_POISON_CANCEL_STATUS", status,
                  RDMA_SC_INVALID_STATE);
    if (completions.size() != 0 ||
        engine.state() != RDMA_CMQ_ENGINE_POISONED ||
        engine.published_count() != before_publish ||
        engine.retired_count() != before_retire ||
        engine.cq_consumed_count() != before_consume ||
        engine.slot_record_count() != before_slots ||
        engine.tokens_in_use_count() != before_tokens ||
        engine.command_registry_count() != before_commands ||
        engine.entry_registry_count() != before_entries ||
        engine.terminal_fifo_count() != 1 ||
        engine.diagnostic_fifo_count() != 1)
      `uvm_error("WAIT_POISON_CANCEL_ATOMICITY",
                 "public cancel recovered or changed poisoned authority")

    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("WAIT_POISON_DIAGNOSTIC_STATUS", status,
                  RDMA_SC_INVALID_STATE);
    if (completions.size() != 0 || diagnostics.size() != 1 ||
        diagnostics[0] == null ||
        diagnostics[0].kind != RDMA_CMQ_DIAG_MALFORMED_CQE ||
        engine.terminal_fifo_count() != 1 ||
        engine.diagnostic_fifo_count() != 0 ||
        count_host_calls(mem, "read") != 0)
      `uvm_error("WAIT_POISON_DIAGNOSTIC_DRAIN",
                 "non-ACTIVE poll did not drain only one diagnostic")
    engine.poll(completions, diagnostics, status);
    expect_status("WAIT_POISON_DIAGNOSTIC_ONCE_STATUS", status,
                  RDMA_SC_INVALID_STATE);
    if (completions.size() != 0 || diagnostics.size() != 0 ||
        engine.terminal_fifo_count() != 1 ||
        engine.diagnostic_fifo_count() != 0 ||
        count_host_calls(mem, "read") != 0 ||
        engine.last_poison_snapshot() == null)
      `uvm_error("WAIT_POISON_DIAGNOSTIC_ONCE",
                 "poison diagnostic repeated or normal FIFO was drained")

    engine.reset(completions, status);
    expect_status("WAIT_POISON_RESET", status, RDMA_SC_OK);
    normal_count = 0;
    cancel_count = 0;
    foreach (completions[i]) begin
      if (completions[i] != null && completions[i].ticket != null &&
          completions[i].status != null &&
          completions[i].ticket.command_id == tickets[0].command_id &&
          completions[i].status.code == RDMA_SC_OK)
        normal_count++;
      if (completions[i] != null && completions[i].ticket != null &&
          completions[i].status != null &&
          completions[i].ticket.command_id == tickets[1].command_id &&
          completions[i].status.code == RDMA_SC_RESET_CANCELLED)
        cancel_count++;
    end
    if (completions.size() != 2 || normal_count != 1 ||
        cancel_count != 1 || engine.last_poison_snapshot() != null)
      `uvm_error("WAIT_POISON_RESET_RESULTS",
                 "reset did not return queued result and trusted cancel")
    expect_unconfigured("WAIT_POISON_RESET_STATE", engine);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_wait_for_caller_ticket_detachment 中构造或驱动“wait for caller ticket
  //   detachment”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_wait_for_caller_ticket_detachment();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc requests[];
    rdma_cmq_command_desc request_c;
    rdma_cmq_ticket tickets[];
    rdma_cmq_ticket original_a;
    rdma_cmq_ticket ticket_c;
    rdma_cmq_ticket clone_fault_ticket;
    rdma_cmq_clone_fault_function_handle clone_fault_function;
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_cmq_completion waited_completion;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_a;
    rdma_hw_image raw_b;
    rdma_hw_image raw_c;
    rdma_status wait_status;
    rdma_status status;
    longint unsigned command_id_a;
    longint unsigned command_id_b;

    engine = rdma_cmq_engine_probe::type_id::create(
      "wait_detached_ticket_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("wait_detached_ticket_mem");
    pcie = rdma_cmq_test_pcie::type_id::create(
      "wait_detached_ticket_pcie"
    );
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "wait_detached_ticket_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "wait_detached_ticket_profile"
    );
    prepared_binding = make_binding(
      "wait_detached_ticket_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "wait_detached_ticket_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("wait_detached_ticket_cmq", prepared_binding);
    prepare_active(
      "WAIT_DETACHED_TICKET", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    mapping = engine.mapping_snapshot();

    requests = new[2];
    requests[0] = make_command(
      "wait_detached_ticket_a", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h61, 100ns
    );
    requests[1] = make_command(
      "wait_detached_ticket_b", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'h62, 100ns
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("WAIT_DETACHED_TICKET_SUBMIT", batch_status, RDMA_SC_OK);
    if (tickets.size() != 2 || tickets[0] == null || tickets[1] == null) begin
      `uvm_error("WAIT_DETACHED_TICKET_SUBMIT",
                 "two-ticket mutation fixture is incomplete")
      engine.shutdown(status);
      return;
    end
    command_id_a = tickets[0].command_id;
    command_id_b = tickets[1].command_id;
    original_a = rdma_cmq_ticket::type_id::create(
      "wait_detached_ticket_original_a"
    );
    original_a.copy(tickets[0]);

    // wait_for releases the engine lock for its 1ns wait interval.  Mutate
    // the exact caller-owned ticket handle to the other valid outstanding
    // command during that interval, then complete B before A.
    fork
      begin
        engine.wait_for(tickets[0], waited_completion, wait_status);
      end
      begin
        #500ps;
        tickets[0].copy(tickets[1]);
        #250ps;
        write_profile_cqe(
          "WAIT_DETACHED_TICKET_B", mem, mapping, profile, 0, 1'b1,
          tickets[1], 0, raw_b
        );
        #1ns;
        write_profile_cqe(
          "WAIT_DETACHED_TICKET_A", mem, mapping, profile, 1, 1'b1,
          original_a, 0, raw_a
        );
      end
    join
    expect_status("WAIT_DETACHED_TICKET_WAIT", wait_status, RDMA_SC_OK);
    if (waited_completion == null || waited_completion.ticket == null ||
        waited_completion.ticket.command_id != command_id_a)
      `uvm_error("WAIT_DETACHED_TICKET_WAIT",
                 "wait_for followed caller mutation away from ticket A")

    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("WAIT_DETACHED_TICKET_POLL_B", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0 ||
        completions[0] == null || completions[0].ticket == null ||
        completions[0].ticket.command_id != command_id_b)
      `uvm_error("WAIT_DETACHED_TICKET_POLL_B",
                 "wait_for consumed B or left A in the terminal FIFO")
    expect_poll_read_geometry("WAIT_DETACHED_TICKET_POLL_B_READ", mem, 2, 1);

    // A hostile but value-valid Function clone must be rejected before an
    // already queued completion is consumed from the terminal FIFO.
    request_c = make_command(
      "wait_detached_ticket_c", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h63, 100ns
    );
    engine.submit(request_c, ticket_c, status);
    expect_status("WAIT_DETACHED_TICKET_SUBMIT_C", status, RDMA_SC_OK);
    write_profile_cqe(
      "WAIT_DETACHED_TICKET_C", mem, mapping, profile, 2, 1'b1,
      ticket_c, 0, raw_c
    );
    engine.poll(completions, diagnostics, status);
    expect_status("WAIT_DETACHED_TICKET_POLL_C", status, RDMA_SC_OK);
    if (completions.size() != 1 || completions[0] == null ||
        completions[0].ticket == null ||
        completions[0].ticket.command_id != ticket_c.command_id ||
        diagnostics.size() != 0) begin
      `uvm_error("WAIT_DETACHED_TICKET_POLL_C",
                 "snapshot-failure FIFO fixture did not complete C")
      engine.shutdown(status);
      return;
    end
    engine.seed_terminal_completion(completions[0]);
    clone_fault_ticket = rdma_cmq_ticket::type_id::create(
      "wait_detached_ticket_clone_fault"
    );
    clone_fault_ticket.copy(ticket_c);
    clone_fault_function =
      rdma_cmq_clone_fault_function_handle::type_id::create(
        "wait_detached_ticket_clone_fault_function"
      );
    clone_fault_function.kind = ticket_c.function_h.kind;
    clone_fault_function.function_uid = ticket_c.function_h.function_uid;
    clone_fault_function.object_id = ticket_c.function_h.object_id;
    clone_fault_function.generation = ticket_c.function_h.generation;
    clone_fault_function.clone_fault = RDMA_CMQ_TEST_CLONE_NULL;
    clone_fault_ticket.function_h = clone_fault_function;

    mem.calls.delete();
    engine.wait_for(clone_fault_ticket, waited_completion, status);
    expect_status("WAIT_DETACHED_TICKET_CLONE_FAILURE", status,
                  RDMA_SC_INVALID_STATE);
    if (waited_completion != null || engine.terminal_fifo_count() != 1 ||
        count_host_calls(mem, "read") != 0)
      `uvm_error("WAIT_DETACHED_TICKET_CLONE_FAILURE",
                 "snapshot failure consumed FIFO or touched CQ backing")
    engine.wait_for(ticket_c, waited_completion, status);
    expect_status("WAIT_DETACHED_TICKET_CLONE_RETRY", status, RDMA_SC_OK);
    if (waited_completion == null || waited_completion.ticket == null ||
        waited_completion.ticket.command_id != ticket_c.command_id ||
        engine.terminal_fifo_count() != 0 ||
        count_host_calls(mem, "read") != 0)
      `uvm_error("WAIT_DETACHED_TICKET_CLONE_RETRY",
                 "valid retry did not consume the retained FIFO item once")

    engine.shutdown(status);
    expect_status("WAIT_DETACHED_TICKET_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_wait_for_fifo_and_deadline 中构造或驱动“wait for fifo and deadline”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_wait_for_fifo_and_deadline();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_cmq_ticket unknown_ticket;
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_cmq_completion completion;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_b;
    rdma_hw_image raw_a;
    rdma_status status;

    engine = rdma_cmq_engine_probe::type_id::create("wait_fifo_engine");
    mem = rdma_mock_host_mem::type_id::create("wait_fifo_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("wait_fifo_pcie");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "wait_fifo_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("wait_fifo_profile");
    prepared_binding = make_binding("wait_fifo_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("wait_fifo_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("wait_fifo_cmq", prepared_binding);
    prepare_active("WAIT_FIFO", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    requests = new[2];
    requests[0] = make_command(
      "wait_fifo_a", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h41, 20ns
    );
    requests[1] = make_command(
      "wait_fifo_b", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'h42, 20ns
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("WAIT_FIFO_SUBMIT", batch_status, RDMA_SC_OK);
    mapping = engine.mapping_snapshot();
    write_profile_cqe("WAIT_FIFO_B", mem, mapping, profile, 0, 1'b1,
                      tickets[1], 0, raw_b);
    fork
      begin
        #2ns;
        write_profile_cqe("WAIT_FIFO_A", mem, mapping, profile, 1, 1'b1,
                          tickets[0], 0, raw_a);
      end
    join_none
    engine.wait_for(tickets[0], completion, status);
    wait fork;
    expect_status("WAIT_FIFO_WAIT_A", status, RDMA_SC_OK);
    if (completion == null || completion.ticket == null ||
        completion.ticket.command_id != tickets[0].command_id)
      `uvm_error("WAIT_FIFO_WAIT_A", "wait_for did not return ticket A")
    engine.poll(completions, diagnostics, status);
    expect_status("WAIT_FIFO_POLL_B", status, RDMA_SC_OK);
    if (completions.size() != 1 || completions[0].ticket == null ||
        completions[0].ticket.command_id != tickets[1].command_id ||
        diagnostics.size() != 0)
      `uvm_error("WAIT_FIFO_POLL_B", "wait_for consumed queued ticket B")
    engine.poll(completions, diagnostics, status);
    expect_status("WAIT_FIFO_POLL_ONCE", status, RDMA_SC_OK);
    if (completions.size() != 0 || diagnostics.size() != 0)
      `uvm_error("WAIT_FIFO_POLL_ONCE", "completion was delivered twice")
    engine.wait_for(tickets[1], completion, status);
    expect_status("WAIT_FIFO_ALREADY_DELIVERED", status,
                  RDMA_SC_INVALID_ARGUMENT);
    if (completion != null)
      `uvm_error("WAIT_FIFO_ALREADY_DELIVERED",
                 "already delivered wait returned a completion")
    unknown_ticket = rdma_cmq_ticket::type_id::create("wait_unknown_ticket");
    unknown_ticket.copy(tickets[1]);
    unknown_ticket.command_id += 32;
    engine.wait_for(unknown_ticket, completion, status);
    expect_status("WAIT_FIFO_UNKNOWN", status, RDMA_SC_INVALID_ARGUMENT);
    if (completion != null)
      `uvm_error("WAIT_FIFO_UNKNOWN", "unknown wait returned completion")
    requests = new[2];
    requests[0] = make_command(
      "wait_fifo_c", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h44, 20ns
    );
    requests[1] = make_command(
      "wait_fifo_d", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'h45, 20ns
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("WAIT_FIFO_SUBMIT_CD", batch_status, RDMA_SC_OK);
    write_profile_cqe("WAIT_FIFO_D", mem, mapping, profile, 2, 1'b1,
                      tickets[1], 0, raw_b);
    fork
      begin
        #2ns;
        write_profile_cqe("WAIT_FIFO_C", mem, mapping, profile, 3, 1'b1,
                          tickets[0], 0, raw_a);
      end
    join_none
    engine.wait_for(tickets[0], completion, status);
    wait fork;
    expect_status("WAIT_FIFO_WAIT_C", status, RDMA_SC_OK);
    mem.calls.delete();
    engine.wait_for(tickets[1], completion, status);
    expect_status("WAIT_FIFO_DIRECT_D", status, RDMA_SC_OK);
    if (completion == null || completion.ticket == null ||
        completion.ticket.command_id != tickets[1].command_id ||
        count_host_calls(mem, "read") != 0)
      `uvm_error("WAIT_FIFO_DIRECT_D",
                 "queued wait target caused a new host read")
    engine.shutdown(status);
    expect_status("WAIT_FIFO_SHUTDOWN", status, RDMA_SC_OK);

    engine = rdma_cmq_engine_probe::type_id::create("wait_timeout_engine");
    mem = rdma_mock_host_mem::type_id::create("wait_timeout_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("wait_timeout_pcie");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "wait_timeout_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("wait_timeout_profile");
    prepared_binding = make_binding("wait_timeout_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("wait_timeout_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("wait_timeout_cmq", prepared_binding);
    prepare_active("WAIT_TIMEOUT", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    requests = new[1];
    requests[0] = make_command(
      "wait_timeout_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h43, 3ns
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("WAIT_TIMEOUT_SUBMIT", batch_status, RDMA_SC_OK);
    engine.wait_for(tickets[0], completion, status);
    expect_status("WAIT_TIMEOUT_WAIT", status, RDMA_SC_OK);
    if (completion == null || completion.status == null ||
        completion.status.code != RDMA_SC_TIMEOUT ||
        $time != tickets[0].absolute_deadline)
      `uvm_error("WAIT_TIMEOUT_WAIT",
                 "wait_for did not expire at the exact absolute deadline")
    if (engine.outstanding_count() != 0 ||
        engine.quarantine_count() != 1)
      `uvm_error("WAIT_TIMEOUT_COUNTS",
                 "detached outstanding/quarantine counts are wrong")
    engine.wait_for(tickets[0], completion, status);
    expect_status("WAIT_TIMEOUT_ALREADY_DELIVERED", status,
                  RDMA_SC_INVALID_ARGUMENT);
    engine.shutdown(status);
    expect_status("WAIT_TIMEOUT_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_cancel_reset_and_shutdown_lifecycle 中构造或驱动“cancel reset and shutdown
  //   lifecycle”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_cancel_reset_and_shutdown_lifecycle();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping old_mapping;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_cmq_ticket published_ticket;
    rdma_cmq_ticket reuse_ticket;
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_cmq_completion completions[$];
    rdma_status status;
    byte data[];
    byte one[];
    int unsigned release_calls;

    engine = rdma_cmq_engine_probe::type_id::create("cancel_engine");
    mem = rdma_mock_host_mem::type_id::create("cancel_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("cancel_pcie");
    scheduler = rdma_doorbell_scheduler::type_id::create("cancel_scheduler");
    profile = rdma_cmq_test_profile::type_id::create("cancel_profile");
    prepared_binding = make_binding("cancel_prepared", RDMA_BIND_PREPARED);
    active_binding = make_binding("cancel_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("cancel_cmq", prepared_binding);
    prepare_active("CANCEL", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    requests = new[2];
    requests[0] = make_command(
      "cancel_timeout", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h51, 2ns
    );
    requests[1] = make_command(
      "cancel_published", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'h52, 20ns
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("CANCEL_SUBMIT", batch_status, RDMA_SC_OK);
    published_ticket = tickets[1];
    #2ns;
    engine.expire(completions, status);
    expect_status("CANCEL_EXPIRE", status, RDMA_SC_OK);
    if (completions.size() != 1 || completions[0].status == null ||
        completions[0].status.code != RDMA_SC_TIMEOUT)
      `uvm_error("CANCEL_EXPIRE", "timeout setup did not deliver once")
    requests = new[1];
    requests[0] = make_command(
      "cancel_reuse", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h53, 20ns
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("CANCEL_REUSE_SUBMIT", batch_status, RDMA_SC_OK);
    reuse_ticket = tickets[0];
    if (reuse_ticket == null || reuse_ticket.command_id[4:0] != 0 ||
        reuse_ticket.command_id[63:5] == 0 ||
        !engine.token_in_use_at(reuse_ticket.command_id[4:0]))
      `uvm_error("CANCEL_REUSE_SUBMIT",
                 "timeout token was not reused by a newer incarnation")
    engine.cancel_generation(active_binding.generation + 1,
                             completions, status);
    expect_status("CANCEL_STALE", status, RDMA_SC_STALE_GENERATION);
    if (completions.size() != 0 || engine.outstanding_count() != 2 ||
        engine.quarantine_count() != 1 ||
        engine.state() != RDMA_CMQ_ENGINE_ACTIVE)
      `uvm_error("CANCEL_STALE", "stale cancel changed engine authority")
    engine.cancel_generation(active_binding.generation,
                             completions, status);
    expect_status("CANCEL_CURRENT", status, RDMA_SC_OK);
    if (completions.size() != 2)
      `uvm_error("CANCEL_CURRENT", "cancel did not return two completions")
    else if (completions[0] == null || completions[1] == null ||
        completions[0].ticket == null ||
        completions[0].status == null || completions[1].ticket == null ||
        completions[1].status == null ||
        completions[0].status.code != RDMA_SC_RESET_CANCELLED ||
        completions[1].status.code != RDMA_SC_RESET_CANCELLED ||
        completions[0].status.source_engine != RDMA_ENGINE_RESET ||
        completions[1].status.source_engine != RDMA_ENGINE_RESET ||
        completions[0].status.function_uid != active_binding.function_uid ||
        completions[0].status.generation != active_binding.generation ||
        completions[0].status.resource_id != cmq.handle.object_id ||
        completions[0].status.command_id != completions[0].ticket.command_id ||
        completions[1].status.command_id != completions[1].ticket.command_id ||
        !((completions[0].ticket.command_id == reuse_ticket.command_id &&
           completions[1].ticket.command_id == published_ticket.command_id) ||
          (completions[1].ticket.command_id == reuse_ticket.command_id &&
           completions[0].ticket.command_id == published_ticket.command_id)))
      `uvm_error("CANCEL_CURRENT", "cancel completion identity is wrong")
    if (engine.state() != RDMA_CMQ_ENGINE_QUIESCED ||
        engine.outstanding_count() != 0 || engine.quarantine_count() != 0 ||
        engine.published_count() != 0 || engine.retired_count() != 0 ||
        engine.cq_consumed_count() != 0 ||
        engine.tokens_in_use_count() != 0 ||
        engine.slot_record_count() != 0 ||
        engine.command_registry_count() != 0 ||
        engine.entry_registry_count() != 0)
      `uvm_error("CANCEL_CURRENT", "cancel did not quiesce every ledger")
    old_mapping = engine.mapping_snapshot();
    release_calls = count_host_calls(mem, "release");
    engine.shutdown(status);
    expect_status("CANCEL_QUIESCED_SHUTDOWN", status, RDMA_SC_OK);
    expect_unconfigured("CANCEL_QUIESCED_SHUTDOWN_STATE", engine);
    if (count_host_calls(mem, "release") != release_calls + 1)
      `uvm_error("CANCEL_QUIESCED_SHUTDOWN",
                 "QUIESCED shutdown did not release exactly once")
    data = new[0];
    status = mem.read(old_mapping, 0, 1, data);
    if (status == null || status.ok())
      `uvm_error("CANCEL_RESET_OLD_READ",
                 "released mapping still accepted a read")
    one = new[1];
    one[0] = 8'ha5;
    status = mem.write(old_mapping, 0, one);
    if (status == null || status.ok())
      `uvm_error("CANCEL_RESET_OLD_WRITE",
                 "released mapping still accepted a write")
    engine.shutdown(status);
    expect_status("CANCEL_SHUTDOWN_IDEMPOTENT", status, RDMA_SC_OK);
    if (count_host_calls(mem, "release") != release_calls + 1)
      `uvm_error("CANCEL_SHUTDOWN_IDEMPOTENT",
                 "idempotent shutdown released twice")
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_strict_cancel_audits_complete_ledger 中构造或驱动“strict cancel audits complete
  //   ledger”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_strict_cancel_audits_complete_ledger();
    string fault_labels[4];
    int unsigned request_counts[4];
    int unsigned recovery_counts[4];

    fault_labels[0] = "STRAY_TOKEN";
    fault_labels[1] = "MOVED_SLOT";
    fault_labels[2] = "DUPLICATE_SLOT";
    fault_labels[3] = "WRONG_COMMAND_KEY";
    request_counts[0] = 1;
    request_counts[1] = 1;
    request_counts[2] = 2;
    request_counts[3] = 1;
    recovery_counts[0] = 1;
    recovery_counts[1] = 0;
    recovery_counts[2] = 1;
    recovery_counts[3] = 1;
    for (int unsigned fault = 0; fault < 4; fault++) begin
      rdma_cmq_engine_probe engine;
      rdma_mock_host_mem mem;
      rdma_cmq_test_pcie pcie;
      rdma_doorbell_scheduler scheduler;
      rdma_cmq_test_profile profile;
      rdma_function_binding prepared_binding;
      rdma_function_binding active_binding;
      rdma_cmq cmq;
      rdma_cmq_runtime_desc runtime_desc;
      rdma_cmq_command_desc requests[];
      rdma_cmq_ticket tickets[];
      rdma_status item_statuses[];
      rdma_status batch_status;
      rdma_cmq_completion completions[$];
      rdma_status status;
      string label;
      longint unsigned before_publish;
      longint unsigned before_retire;
      longint unsigned before_consume;
      int unsigned before_slots;
      int unsigned before_tokens;
      int unsigned before_commands;
      int unsigned before_entries;

      label = {"STRICT_CANCEL_AUDIT_", fault_labels[fault]};
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("strict_cancel_audit_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("strict_cancel_audit_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("strict_cancel_audit_pcie_%0d", fault)
      );
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("strict_cancel_audit_scheduler_%0d", fault)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("strict_cancel_audit_profile_%0d", fault)
      );
      prepared_binding = make_binding(
        $sformatf("strict_cancel_audit_prepared_%0d", fault),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("strict_cancel_audit_active_%0d", fault),
        RDMA_BIND_ACTIVE
      );
      cmq = make_cmq(
        $sformatf("strict_cancel_audit_cmq_%0d", fault),
        prepared_binding
      );
      prepare_active(
        label, engine, mem, pcie, scheduler, profile, prepared_binding,
        active_binding, cmq, runtime_desc
      );
      requests = new[request_counts[fault]];
      foreach (requests[i]) begin
        requests[i] = make_command(
          $sformatf("strict_cancel_audit_request_%0d_%0d", fault, i),
          active_binding, rdma_cmq_test_profile::TEST_OPCODE_A,
          byte'(8'hd0 + (fault * 2) + i), 10us
        );
      end
      engine.submit_batch(requests, tickets, item_statuses, batch_status);
      expect_status({label, "_SUBMIT"}, batch_status, RDMA_SC_OK);
      if (!engine.tamper_cancel_ledger(
            tickets, rdma_cmq_test_cancel_ledger_fault_e'(fault)
          ))
        `uvm_error(label, "strict cancel ledger tamper setup failed")
      before_publish = engine.published_count();
      before_retire = engine.retired_count();
      before_consume = engine.cq_consumed_count();
      before_slots = engine.slot_record_count();
      before_tokens = engine.tokens_in_use_count();
      before_commands = engine.command_registry_count();
      before_entries = engine.entry_registry_count();

      engine.cancel_generation(
        active_binding.generation, completions, status
      );
      expect_status({label, "_STATUS"}, status, RDMA_SC_INVALID_STATE);
      if (completions.size() != 0 ||
          engine.state() != RDMA_CMQ_ENGINE_POISONED ||
          engine.published_count() != before_publish ||
          engine.retired_count() != before_retire ||
          engine.cq_consumed_count() != before_consume ||
          engine.slot_record_count() != before_slots ||
          engine.tokens_in_use_count() != before_tokens ||
          engine.command_registry_count() != before_commands ||
          engine.entry_registry_count() != before_entries ||
          engine.terminal_fifo_count() != 0 ||
          engine.diagnostic_fifo_count() != 0)
        `uvm_error({label, "_ATOMICITY"},
                   "strict cancel did not poison before ledger mutation")

      engine.reset(completions, status);
      expect_status({label, "_RESET"}, status, RDMA_SC_OK);
      if (completions.size() != recovery_counts[fault] ||
          count_host_calls(mem, "release") != 1)
        `uvm_error({label, "_RECOVERY"},
                   "reset did not recover the trusted ticket set")
      foreach (completions[i]) begin
        if (completions[i] == null || completions[i].status == null ||
            completions[i].status.code != RDMA_SC_RESET_CANCELLED)
          `uvm_error({label, "_RECOVERY"},
                     "reset returned a non-cancellation completion")
      end
      expect_unconfigured({label, "_STATE"}, engine);
    end
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_strict_cancel_audits_exact_membership 中构造或驱动“strict cancel audits exact
  //   membership”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_strict_cancel_audits_exact_membership();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_cmq_completion completions[$];
    rdma_status status;
    rdma_status cleanup_status;
    longint unsigned before_publish;
    longint unsigned before_retire;
    longint unsigned before_consume;
    int unsigned before_slots;
    int unsigned before_tokens;
    int unsigned before_commands;
    int unsigned before_entries;
    int unsigned before_terminal;
    int unsigned before_diagnostics;

    engine = rdma_cmq_engine_probe::type_id::create(
      "strict_cancel_membership_engine"
    );
    mem = rdma_mock_host_mem::type_id::create(
      "strict_cancel_membership_mem"
    );
    pcie = rdma_cmq_test_pcie::type_id::create(
      "strict_cancel_membership_pcie"
    );
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "strict_cancel_membership_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "strict_cancel_membership_profile"
    );
    prepared_binding = make_binding(
      "strict_cancel_membership_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "strict_cancel_membership_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("strict_cancel_membership_cmq", prepared_binding);
    prepare_active(
      "STRICT_CANCEL_MEMBERSHIP", engine, mem, pcie, scheduler, profile,
      prepared_binding, active_binding, cmq, runtime_desc
    );
    requests = new[2];
    requests[0] = make_command(
      "strict_cancel_membership_timeout", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'he8, 10ns
    );
    requests[1] = make_command(
      "strict_cancel_membership_published", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'he9, 10us
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("STRICT_CANCEL_MEMBERSHIP_SUBMIT", batch_status,
                  RDMA_SC_OK);
    #20ns;
    engine.expire(completions, status);
    expect_status("STRICT_CANCEL_MEMBERSHIP_EXPIRE", status, RDMA_SC_OK);
    if (completions.size() != 1 || completions[0] == null ||
        completions[0].status == null ||
        completions[0].status.code != RDMA_SC_TIMEOUT ||
        engine.slot_state_at(tickets[0].sq_index) !=
          CMQ_SLOT_TIMED_OUT_QUARANTINED ||
        engine.slot_state_at(tickets[1].sq_index) != CMQ_SLOT_PUBLISHED)
      `uvm_error("STRICT_CANCEL_MEMBERSHIP_EXPIRE",
                 "fixture did not create quarantined and published slots")
    if (!engine.tamper_balanced_cancel_membership(
          tickets[0], tickets[1]
        ))
      `uvm_error("STRICT_CANCEL_MEMBERSHIP_TAMPER",
                 "balanced stray-membership tamper failed")
    before_publish = engine.published_count();
    before_retire = engine.retired_count();
    before_consume = engine.cq_consumed_count();
    before_slots = engine.slot_record_count();
    before_tokens = engine.tokens_in_use_count();
    before_commands = engine.command_registry_count();
    before_entries = engine.entry_registry_count();
    before_terminal = engine.terminal_fifo_count();
    before_diagnostics = engine.diagnostic_fifo_count();
    if (before_slots != 2 || before_tokens != 2 ||
        before_commands != 2 || before_entries != 2)
      `uvm_error("STRICT_CANCEL_MEMBERSHIP_TAMPER",
                 "tamper did not preserve the intended coarse counts")

    engine.cancel_generation(
      active_binding.generation, completions, status
    );
    expect_status("STRICT_CANCEL_BALANCED_MEMBERSHIP_STATUS", status,
                  RDMA_SC_INVALID_STATE);
    if (completions.size() != 0 ||
        engine.state() != RDMA_CMQ_ENGINE_POISONED ||
        engine.published_count() != before_publish ||
        engine.retired_count() != before_retire ||
        engine.cq_consumed_count() != before_consume ||
        engine.slot_record_count() != before_slots ||
        engine.tokens_in_use_count() != before_tokens ||
        engine.command_registry_count() != before_commands ||
        engine.entry_registry_count() != before_entries ||
        engine.terminal_fifo_count() != before_terminal ||
        engine.diagnostic_fifo_count() != before_diagnostics)
      `uvm_error("STRICT_CANCEL_BALANCED_MEMBERSHIP_ATOMICITY",
                 "strict cancel mutated a balanced stray membership")

    engine.reset(completions, status);
    expect_status("STRICT_CANCEL_BALANCED_MEMBERSHIP_RESET", status,
                  RDMA_SC_OK);
    if (status == null || !status.ok()) begin
      engine.shutdown(cleanup_status);
      return;
    end
    if (completions.size() != 1 || completions[0] == null ||
        completions[0].ticket == null || completions[0].status == null ||
        completions[0].ticket.command_id != tickets[1].command_id ||
        completions[0].status.code != RDMA_SC_RESET_CANCELLED ||
        count_host_calls(mem, "release") != 1)
      `uvm_error("STRICT_CANCEL_BALANCED_MEMBERSHIP_RECOVERY",
                 "reset did not safely clear and release the poisoned set")
    expect_unconfigured("STRICT_CANCEL_BALANCED_MEMBERSHIP_STATE", engine);
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_poison_recovery_rejects_x_tickets 中构造或驱动“poison recovery rejects x
  //   tickets”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_poison_recovery_rejects_x_tickets();
    string fault_labels[2];

    fault_labels[0] = "COMMAND_ID";
    fault_labels[1] = "ABSOLUTE_DEADLINE";
    for (int unsigned fault = 0; fault < 2; fault++) begin
      rdma_cmq_engine_probe engine;
      rdma_mock_host_mem mem;
      rdma_cmq_test_pcie pcie;
      rdma_doorbell_scheduler scheduler;
      rdma_cmq_test_profile profile;
      rdma_function_binding prepared_binding;
      rdma_function_binding active_binding;
      rdma_cmq cmq;
      rdma_cmq_runtime_desc runtime_desc;
      rdma_cmq_command_desc request;
      rdma_cmq_ticket ticket;
      rdma_cmq_completion completions[$];
      rdma_cmq_diagnostic diagnostics[$];
      rdma_status status;
      string label;
      int unsigned token_index;
      bit [58:0] incarnation;

      label = {"RECOVERY_X_", fault_labels[fault]};
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("recovery_x_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("recovery_x_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("recovery_x_pcie_%0d", fault)
      );
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("recovery_x_scheduler_%0d", fault)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("recovery_x_profile_%0d", fault)
      );
      prepared_binding = make_binding(
        $sformatf("recovery_x_prepared_%0d", fault), RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("recovery_x_active_%0d", fault), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq(
        $sformatf("recovery_x_cmq_%0d", fault), prepared_binding
      );
      prepare_active(
        label, engine, mem, pcie, scheduler, profile, prepared_binding,
        active_binding, cmq, runtime_desc
      );
      request = make_command(
        $sformatf("recovery_x_request_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'he0 + fault), 10us
      );
      engine.submit(request, ticket, status);
      expect_status({label, "_SUBMIT"}, status, RDMA_SC_OK);
      token_index = ticket.command_id[4:0];
      incarnation = engine.token_incarnation_at(token_index);
      if (!engine.tamper_recovery_ticket_x(
            ticket, rdma_cmq_test_recovery_x_fault_e'(fault)
          ))
        `uvm_error(label, "recovery X tamper setup failed")

      mem.calls.delete();
      engine.poll(completions, diagnostics, status);
      expect_status({label, "_POLL"}, status, RDMA_SC_INVALID_STATE);
      if (engine.state() != RDMA_CMQ_ENGINE_POISONED ||
          completions.size() != 0 || diagnostics.size() != 0 ||
          count_host_calls(mem, "read") != 0)
        `uvm_error({label, "_POISON"},
                   "X ticket setup did not poison before transport")
      engine.reset(completions, status);
      expect_status({label, "_RESET"}, status, RDMA_SC_OK);
      if (completions.size() != 0 ||
          engine.token_incarnation_at(token_index) != incarnation ||
          count_host_calls(mem, "release") != 1)
        `uvm_error({label, "_TRUST"},
                   "reset trusted X ticket or rewound incarnation")
      expect_unconfigured({label, "_STATE"}, engine);
    end
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_poisoned_ledger_reset_recovery 中构造或驱动“poisoned ledger reset recovery”场景，并断言
  //   DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_poisoned_ledger_reset_recovery();
    string fault_labels[3];
    bit expect_cancel[3];

    fault_labels[0] = "TOKEN_MISSING";
    fault_labels[1] = "SLOT_MISSING";
    fault_labels[2] = "REGISTRY_MISSING";
    expect_cancel[0] = 1'b1;
    expect_cancel[1] = 1'b0;
    expect_cancel[2] = 1'b1;
    for (int unsigned fault = 0; fault < 3; fault++) begin
      rdma_cmq_engine_probe engine;
      rdma_mock_host_mem mem;
      rdma_cmq_test_pcie pcie;
      rdma_doorbell_scheduler scheduler;
      rdma_cmq_test_profile profile;
      rdma_function_binding prepared_binding;
      rdma_function_binding active_binding;
      rdma_cmq cmq;
      rdma_cmq_runtime_desc runtime_desc;
      rdma_dma_mapping mapping;
      rdma_cmq_command_desc request;
      rdma_cmq_ticket ticket;
      rdma_cmq_completion completions[$];
      rdma_cmq_diagnostic diagnostics[$];
      rdma_status status;
      rdma_status cleanup_status;
      byte data[];
      byte one[];
      int unsigned expected_release_calls;
      string label;

      label = {"POISONED_LEDGER_", fault_labels[fault]};
      engine = rdma_cmq_engine_probe::type_id::create(
        $sformatf("poisoned_ledger_engine_%0d", fault)
      );
      mem = rdma_mock_host_mem::type_id::create(
        $sformatf("poisoned_ledger_mem_%0d", fault)
      );
      pcie = rdma_cmq_test_pcie::type_id::create(
        $sformatf("poisoned_ledger_pcie_%0d", fault)
      );
      scheduler = rdma_doorbell_scheduler::type_id::create(
        $sformatf("poisoned_ledger_scheduler_%0d", fault)
      );
      profile = rdma_cmq_test_profile::type_id::create(
        $sformatf("poisoned_ledger_profile_%0d", fault)
      );
      prepared_binding = make_binding(
        $sformatf("poisoned_ledger_prepared_%0d", fault),
        RDMA_BIND_PREPARED
      );
      active_binding = make_binding(
        $sformatf("poisoned_ledger_active_%0d", fault), RDMA_BIND_ACTIVE
      );
      cmq = make_cmq(
        $sformatf("poisoned_ledger_cmq_%0d", fault), prepared_binding
      );
      prepare_active(
        label, engine, mem, pcie, scheduler, profile, prepared_binding,
        active_binding, cmq, runtime_desc
      );
      request = make_command(
        $sformatf("poisoned_ledger_request_%0d", fault), active_binding,
        rdma_cmq_test_profile::TEST_OPCODE_A, byte'(8'hb0 + fault), 10us
      );
      engine.submit(request, ticket, status);
      expect_status({label, "_SUBMIT"}, status, RDMA_SC_OK);
      mapping = engine.mapping_snapshot();
      if (!engine.tamper_published_ledger(
            ticket, rdma_cmq_test_published_ledger_fault_e'(fault)
          ))
        `uvm_error(label, "published ledger tamper setup failed")

      mem.calls.delete();
      engine.poll(completions, diagnostics, status);
      expect_status({label, "_POLL"}, status, RDMA_SC_INVALID_STATE);
      if (engine.state() != RDMA_CMQ_ENGINE_POISONED ||
          completions.size() != 0 || diagnostics.size() != 0 ||
          count_host_calls(mem, "read") != 0)
        `uvm_error(label, "ledger corruption did not poison before CQ read")

      if (fault == RDMA_CMQ_TEST_PUBLISHED_LEDGER_TOKEN_MISSING) begin
        engine.cancel_generation(active_binding.generation,
                                 completions, status);
        expect_status({label, "_STRICT_CANCEL"}, status,
                      RDMA_SC_INVALID_STATE);
        if (completions.size() != 0 ||
            engine.state() != RDMA_CMQ_ENGINE_POISONED ||
            count_host_calls(mem, "release") != 0)
          `uvm_error(label, "strict public cancel recovered poison")
        expect_status(
          {label, "_ARM_RELEASE_FAIL"},
          mem.fail_next(
            "release",
            rdma_status::make(
              RDMA_SC_UNKNOWN_HW_ERROR,
              "injected poisoned-ledger reset release failure"
            )
          ),
          RDMA_SC_OK
        );
        engine.reset(completions, status);
        expect_status({label, "_RELEASE_FAIL"}, status,
                      RDMA_SC_UNKNOWN_HW_ERROR);
        if (completions.size() != 0 ||
            engine.state() != RDMA_CMQ_ENGINE_POISONED ||
            engine.mapping_snapshot() == null ||
            engine.terminal_fifo_count() != 1 ||
            count_host_calls(mem, "release") != 1 ||
            mem.regions[0].mapping.state != RDMA_MAPPING_ACTIVE)
          `uvm_error(label,
                     "release failure lost staged recovery authority")
      end

      engine.reset(completions, status);
      expect_status({label, "_RESET"}, status, RDMA_SC_OK);
      if (status == null || !status.ok()) begin
        engine.shutdown(cleanup_status);
        continue;
      end
      expect_unconfigured({label, "_STATE"}, engine);
      expected_release_calls =
        (fault == RDMA_CMQ_TEST_PUBLISHED_LEDGER_TOKEN_MISSING) ? 2 : 1;
      if (completions.size() != (expect_cancel[fault] ? 1 : 0) ||
          count_host_calls(mem, "release") != expected_release_calls ||
          mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED ||
          engine.mapping_snapshot() != null ||
          engine.published_count() != 0 || engine.retired_count() != 0 ||
          engine.cq_consumed_count() != 0 ||
          engine.tokens_in_use_count() != 0 ||
          engine.slot_record_count() != 0 ||
          engine.command_registry_count() != 0 ||
          engine.entry_registry_count() != 0)
        `uvm_error(label, "poison recovery did not release all authority")
      if (expect_cancel[fault] &&
          (completions[0] == null || completions[0].ticket == null ||
           completions[0].status == null ||
           completions[0].ticket.command_id != ticket.command_id ||
           completions[0].status.code != RDMA_SC_RESET_CANCELLED ||
           completions[0].status.source_engine != RDMA_ENGINE_RESET ||
           completions[0].status.function_uid !=
             active_binding.function_uid ||
           completions[0].status.generation != active_binding.generation ||
           completions[0].status.resource_id != cmq.handle.object_id ||
           completions[0].status.command_id != ticket.command_id))
        `uvm_error(label, "poison recovery cancellation identity is wrong")

      data = new[0];
      status = mem.read(mapping, 0, 1, data);
      if (status == null || status.ok())
        `uvm_error(label, "poison recovery left old mapping readable")
      one = new[1];
      one[0] = 8'h5a;
      status = mem.write(mapping, 0, one);
      if (status == null || status.ok())
        `uvm_error(label, "poison recovery left old mapping writable")

      engine.reset(completions, status);
      expect_status({label, "_RESET_ONCE"}, status, RDMA_SC_OK);
      if (completions.size() != 0 ||
          count_host_calls(mem, "release") != expected_release_calls)
        `uvm_error(label, "poison recovery delivered or released twice")
    end
  endtask

  // 功能：在测试辅助 rdma_cmq_engine_test.check_reset_fifo_retry_and_reprepare 中构造或驱动“reset fifo retry and reprepare”场景，并断言
  //   DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_reset_fifo_retry_and_reprepare();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_null_release_once_mem null_mem;
    rdma_cmq_test_pcie pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_test_profile profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_function_binding next_prepared;
    rdma_function_binding next_active;
    rdma_cmq cmq;
    rdma_cmq next_cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_dma_mapping mapping;
    rdma_dma_mapping next_mapping;
    rdma_dma_mapping retained_mapping;
    rdma_cmq_command_desc requests[];
    rdma_cmq_ticket tickets[];
    rdma_cmq_ticket first_ticket;
    rdma_cmq_ticket second_ticket;
    rdma_cmq_ticket cancel_ticket;
    rdma_cmq_ticket next_ticket;
    rdma_status item_statuses[];
    rdma_status batch_status;
    rdma_cmq_completion completion;
    rdma_cmq_completion completions[$];
    rdma_cmq_diagnostic diagnostics[$];
    rdma_hw_image raw_b;
    rdma_hw_image raw_a;
    rdma_hw_image poison_raw;
    rdma_status status;
    byte data[];
    byte one[];

    engine = rdma_cmq_engine_probe::type_id::create("reset_fifo_engine");
    mem = rdma_mock_host_mem::type_id::create("reset_fifo_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("reset_fifo_pcie");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "reset_fifo_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("reset_fifo_profile");
    prepared_binding = make_binding("reset_fifo_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("reset_fifo_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("reset_fifo_cmq", prepared_binding);
    prepare_active("RESET_FIFO", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    requests = new[2];
    requests[0] = make_command(
      "reset_fifo_a", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h61, 20ns
    );
    requests[1] = make_command(
      "reset_fifo_b", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_B, 8'h62, 20ns
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("RESET_FIFO_SUBMIT_AB", batch_status, RDMA_SC_OK);
    first_ticket = tickets[0];
    second_ticket = tickets[1];
    mapping = engine.mapping_snapshot();
    write_profile_cqe("RESET_FIFO_B", mem, mapping, profile, 0, 1'b1,
                      second_ticket, 0, raw_b);
    fork
      begin
        #2ns;
        write_profile_cqe("RESET_FIFO_A", mem, mapping, profile, 1, 1'b1,
                          first_ticket, 0, raw_a);
      end
    join_none
    engine.wait_for(first_ticket, completion, status);
    wait fork;
    expect_status("RESET_FIFO_WAIT_A", status, RDMA_SC_OK);
    requests = new[1];
    requests[0] = make_command(
      "reset_fifo_cancel", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h63, 20ns
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("RESET_FIFO_SUBMIT_CANCEL", batch_status, RDMA_SC_OK);
    cancel_ticket = tickets[0];
    engine.reset(completions, status);
    expect_status("RESET_FIFO_RESET", status, RDMA_SC_OK);
    expect_unconfigured("RESET_FIFO_STATE", engine);
    if (completions.size() != 2 || completions[0].ticket == null ||
        completions[1].ticket == null || completions[1].status == null ||
        completions[0].ticket.command_id != second_ticket.command_id ||
        completions[1].ticket.command_id != cancel_ticket.command_id ||
        completions[1].status.code != RDMA_SC_RESET_CANCELLED)
      `uvm_error("RESET_FIFO_RESET",
                 "reset did not preserve terminal-before-cancel FIFO order")
    data = new[0];
    status = mem.read(mapping, 0, 1, data);
    if (status == null || status.ok())
      `uvm_error("RESET_FIFO_OLD_MAPPING",
                 "successful reset left its old mapping active")

    next_prepared = make_binding("reset_fifo_next_prepared",
                                 RDMA_BIND_PREPARED);
    next_active = make_binding("reset_fifo_next_active", RDMA_BIND_ACTIVE);
    next_prepared.generation++;
    next_prepared.synchronize_identity_from_legacy_mirrors();
    next_prepared.owner_h = next_prepared.make_handle();
    next_active.generation++;
    next_active.synchronize_identity_from_legacy_mirrors();
    next_active.owner_h = next_active.make_handle();
    next_cmq = make_cmq("reset_fifo_next_cmq", next_prepared);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "reset_fifo_next_scheduler"
    );
    prepare_active("RESET_FIFO_NEXT", engine, mem, pcie, scheduler, profile,
                   next_prepared, next_active, next_cmq, runtime_desc);
    requests = new[1];
    requests[0] = make_command(
      "reset_fifo_next_request", next_active,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h64, 20ns
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("RESET_FIFO_NEXT_SUBMIT", batch_status, RDMA_SC_OK);
    next_ticket = tickets[0];
    if (next_ticket == null ||
        next_ticket.command_id == first_ticket.command_id ||
        next_ticket.command_id[63:5] <= first_ticket.command_id[63:5])
      `uvm_error("RESET_FIFO_NEXT_INCARNATION",
                 "reset/reprepare rewound command incarnation")
    engine.shutdown(status);
    expect_status("RESET_FIFO_NEXT_SHUTDOWN", status, RDMA_SC_OK);

    engine = rdma_cmq_engine_probe::type_id::create("reset_retry_engine");
    mem = rdma_mock_host_mem::type_id::create("reset_retry_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("reset_retry_pcie");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "reset_retry_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("reset_retry_profile");
    prepared_binding = make_binding("reset_retry_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("reset_retry_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("reset_retry_cmq", prepared_binding);
    prepare_active("RESET_RETRY", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    requests = new[1];
    requests[0] = make_command(
      "reset_retry_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h65, 20ns
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("RESET_RETRY_SUBMIT", batch_status, RDMA_SC_OK);
    cancel_ticket = tickets[0];
    retained_mapping = engine.mapping_snapshot();
    expect_status(
      "RESET_RETRY_ARM",
      mem.fail_next(
        "release",
        rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                          "injected reset release failure")
      ),
      RDMA_SC_OK
    );
    engine.reset(completions, status);
    expect_status("RESET_RETRY_FAIL", status, RDMA_SC_UNKNOWN_HW_ERROR);
    if (completions.size() != 0 ||
        engine.state() != RDMA_CMQ_ENGINE_POISONED ||
        engine.mapping_snapshot() == null ||
        engine.terminal_fifo_count() != 1 ||
        engine.outstanding_count() != 0 ||
        count_host_calls(mem, "release") != 1 ||
        mem.regions[0].mapping.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("RESET_RETRY_FAIL",
                 "failed reset published results or lost retry authority")
    engine.reset(completions, status);
    expect_status("RESET_RETRY_SUCCESS", status, RDMA_SC_OK);
    expect_unconfigured("RESET_RETRY_STATE", engine);
    if (completions.size() != 1 || completions[0].ticket == null ||
        completions[0].status == null ||
        completions[0].ticket.command_id != cancel_ticket.command_id ||
        completions[0].status.code != RDMA_SC_RESET_CANCELLED ||
        count_host_calls(mem, "release") != 2 ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error("RESET_RETRY_SUCCESS",
                 "reset retry did not deliver/release exactly once")

    engine = rdma_cmq_engine_probe::type_id::create(
      "reset_null_retry_engine"
    );
    null_mem = rdma_cmq_null_release_once_mem::type_id::create(
      "reset_null_retry_mem"
    );
    mem = null_mem;
    pcie = rdma_cmq_test_pcie::type_id::create("reset_null_retry_pcie");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "reset_null_retry_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "reset_null_retry_profile"
    );
    prepared_binding = make_binding("reset_null_retry_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("reset_null_retry_active",
                                  RDMA_BIND_ACTIVE);
    cmq = make_cmq("reset_null_retry_cmq", prepared_binding);
    prepare_active("RESET_NULL_RETRY", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    requests = new[1];
    requests[0] = make_command(
      "reset_null_retry_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h67, 20ns
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("RESET_NULL_RETRY_SUBMIT", batch_status, RDMA_SC_OK);
    cancel_ticket = tickets[0];
    engine.reset(completions, status);
    expect_status("RESET_NULL_RETRY_FAIL", status, RDMA_SC_INVALID_STATE);
    if (completions.size() != 0 ||
        engine.state() != RDMA_CMQ_ENGINE_POISONED ||
        engine.mapping_snapshot() == null ||
        engine.terminal_fifo_count() != 1 ||
        count_host_calls(mem, "release") != 1 ||
        mem.regions[0].mapping.state != RDMA_MAPPING_ACTIVE)
      `uvm_error("RESET_NULL_RETRY_FAIL",
                 "null reset release lost FIFO or mapping authority")
    engine.reset(completions, status);
    expect_status("RESET_NULL_RETRY_SUCCESS", status, RDMA_SC_OK);
    expect_unconfigured("RESET_NULL_RETRY_STATE", engine);
    if (completions.size() != 1 || completions[0].ticket == null ||
        completions[0].status == null ||
        completions[0].ticket.command_id != cancel_ticket.command_id ||
        completions[0].status.code != RDMA_SC_RESET_CANCELLED ||
        count_host_calls(mem, "release") != 2 ||
        mem.regions[0].mapping.state != RDMA_MAPPING_RELEASED)
      `uvm_error("RESET_NULL_RETRY_SUCCESS",
                 "null reset retry did not deliver/release exactly once")

    engine = rdma_cmq_engine_probe::type_id::create("poison_reset_engine");
    mem = rdma_mock_host_mem::type_id::create("poison_reset_mem");
    pcie = rdma_cmq_test_pcie::type_id::create("poison_reset_pcie");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "poison_reset_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create("poison_reset_profile");
    prepared_binding = make_binding("poison_reset_prepared",
                                    RDMA_BIND_PREPARED);
    active_binding = make_binding("poison_reset_active", RDMA_BIND_ACTIVE);
    cmq = make_cmq("poison_reset_cmq", prepared_binding);
    prepare_active("POISON_RESET", engine, mem, pcie, scheduler, profile,
                   prepared_binding, active_binding, cmq, runtime_desc);
    requests = new[1];
    requests[0] = make_command(
      "poison_reset_request", active_binding,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h66, 20ns
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("POISON_RESET_SUBMIT", batch_status, RDMA_SC_OK);
    first_ticket = tickets[0];
    mapping = engine.mapping_snapshot();
    write_profile_cqe("POISON_RESET_CQE", mem, mapping, profile, 0, 1'b1,
                      first_ticket, 0, poison_raw);
    poison_raw.bytes[3] = rdma_cmq_test_profile::TEST_OPCODE_B[7:0];
    overwrite_profile_cqe("POISON_RESET_CQE", mem, mapping, 0, poison_raw);
    engine.poll(completions, diagnostics, status);
    expect_status("POISON_RESET_POLL", status, RDMA_SC_CODEC_ERROR);
    if (engine.state() != RDMA_CMQ_ENGINE_POISONED ||
        diagnostics.size() != 1 || engine.last_poison_snapshot() == null)
      `uvm_error("POISON_RESET_POLL", "poison setup lost raw evidence")
    engine.reset(completions, status);
    expect_status("POISON_RESET_RESET", status, RDMA_SC_OK);
    expect_unconfigured("POISON_RESET_STATE", engine);
    if (completions.size() != 1 || completions[0].ticket == null ||
        completions[0].status == null ||
        completions[0].ticket.command_id != first_ticket.command_id ||
        completions[0].status.code != RDMA_SC_RESET_CANCELLED ||
        engine.last_poison_snapshot() != null)
      `uvm_error("POISON_RESET_RESET",
                 "poison reset did not cancel once and clear evidence")
    data = new[0];
    status = mem.read(mapping, 0, 1, data);
    if (status == null || status.ok())
      `uvm_error("POISON_RESET_OLD_MAPPING",
                 "poison reset left old mapping active")
    one = new[1];
    one[0] = 8'ha5;
    status = mem.write(mapping, 0, one);
    if (status == null || status.ok())
      `uvm_error("POISON_RESET_OLD_MAPPING_WRITE",
                 "poison reset left old mapping writable")
    next_prepared = make_binding("poison_reset_next_prepared",
                                 RDMA_BIND_PREPARED);
    next_active = make_binding("poison_reset_next_active", RDMA_BIND_ACTIVE);
    next_prepared.generation++;
    next_prepared.synchronize_identity_from_legacy_mirrors();
    next_prepared.owner_h = next_prepared.make_handle();
    next_active.generation++;
    next_active.synchronize_identity_from_legacy_mirrors();
    next_active.owner_h = next_active.make_handle();
    next_cmq = make_cmq("poison_reset_next_cmq", next_prepared);
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "poison_reset_next_scheduler"
    );
    prepare_active("POISON_RESET_NEXT", engine, mem, pcie, scheduler, profile,
                   next_prepared, next_active, next_cmq, runtime_desc);
    requests = new[1];
    requests[0] = make_command(
      "poison_reset_next_request", next_active,
      rdma_cmq_test_profile::TEST_OPCODE_A, 8'h68, 20ns
    );
    engine.submit_batch(requests, tickets, item_statuses, batch_status);
    expect_status("POISON_RESET_NEXT_SUBMIT", batch_status, RDMA_SC_OK);
    next_ticket = tickets[0];
    next_mapping = engine.mapping_snapshot();
    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("POISON_RESET_NEXT_POLL", status, RDMA_SC_OK);
    if (completions.size() != 0 || diagnostics.size() != 0 ||
        engine.state() != RDMA_CMQ_ENGINE_ACTIVE ||
        engine.outstanding_count() != 1)
      `uvm_error("POISON_RESET_NEXT_POLL",
                 "old generation CQE influenced new generation")
    expect_poll_read_geometry("POISON_RESET_NEXT_READ", mem, 0, 1);
    write_profile_cqe(
      "POISON_RESET_NEXT_CQE", mem, next_mapping, profile, 0, 1'b1,
      next_ticket, 0, raw_a
    );
    mem.calls.delete();
    engine.poll(completions, diagnostics, status);
    expect_status("POISON_RESET_NEXT_COMPLETE", status, RDMA_SC_OK);
    if (completions.size() != 1 || diagnostics.size() != 0 ||
        completions[0] == null || completions[0].ticket == null ||
        completions[0].ticket.command_id != next_ticket.command_id ||
        engine.outstanding_count() != 0)
      `uvm_error("POISON_RESET_NEXT_COMPLETE",
                 "new generation CQE did not complete normally")
    expect_poll_read_geometry("POISON_RESET_NEXT_COMPLETE_READ", mem, 0, 1);
    engine.shutdown(status);
    expect_status("POISON_RESET_NEXT_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：验证 canonical batch key 覆盖完整 Function identity、engine instance
  //   与单调 counters，并验证四个 64-bit overflow 都不回绕。
  // 输入/输出及副作用：无参数；构造独立 engine/binding/mock，执行 prepare/reset/
  //   reprepare 和 protected allocator probe，最后 shutdown 释放本场景 backing。
  // 失败/边界：exact literal、单字段 variation、双 engine、任一 counter 单调性或
  //   prepare overflow-before-I/O 不满足时报告 UVM_ERROR；不依赖 journal query。
  task automatic check_journal_identity_and_counter_contract();
    string expected_key;
    string batch_key;
    string failure_reason;
    string variation_keys[6];
    rdma_function_identity identity;
    rdma_function_identity variations[6];
    rdma_cmq_engine_probe first_engine;
    rdma_cmq_engine_probe second_engine;
    rdma_cmq_engine_probe lifecycle_engine;
    rdma_cmq_engine_probe overflow_engine;
    rdma_mock_host_mem mem;
    rdma_mock_host_mem overflow_mem;
    rdma_doorbell_scheduler scheduler;
    rdma_doorbell_scheduler overflow_scheduler;
    rdma_cmq_test_profile profile;
    rdma_cmq_test_profile overflow_profile;
    rdma_function_binding prepared_binding;
    rdma_function_binding active_binding;
    rdma_function_binding next_prepared;
    rdma_function_binding next_active;
    rdma_function_binding overflow_binding;
    rdma_cmq cmq;
    rdma_cmq next_cmq;
    rdma_cmq overflow_cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_completion reset_completions[$];
    rdma_status status;
    longint unsigned batch_id;
    longint unsigned second_batch_id;
    longint unsigned attempt_id;
    longint unsigned second_attempt_id;
    longint unsigned proof_id;
    longint unsigned second_proof_id;
    longint unsigned old_incarnation;
    bit formatted;

    identity = make_journal_vf_identity("journal_exact_identity");
    status = identity.validate();
    expect_status("JOURNAL_KEY_IDENTITY", status, RDMA_SC_OK);
    expected_key = {
      "root=1234|host=89abcdef|kind=1|parent=2468:9a:1b.2|",
      "vf=1357|bdf=2468:bc:1c.5|gfid=deadbeef|",
      "uid=0123456789abcdef|gen=89abcdef|reset=fedcba9876543210|",
      "engine=1111222233334444|inc=5555666677778888|",
      "batch=9999aaaabbbbcccc"
    };
    formatted = rdma_cmq_format_batch_key(
      identity, 64'h1111_2222_3333_4444, 64'h5555_6666_7777_8888,
      64'h9999_aaaa_bbbb_cccc, batch_key, failure_reason
    );
    if (!formatted || failure_reason != "" || batch_key != expected_key)
      `uvm_error("JOURNAL_KEY_LITERAL",
                 $sformatf("unexpected key '%s' reason '%s'",
                           batch_key, failure_reason))

    variations[0] = copy_journal_identity("journal_parent_variant", identity);
    variations[0].key.parent_pf_bdf.bus++;
    variations[1] = copy_journal_identity("journal_vf_variant", identity);
    variations[1].key.vf_index++;
    variations[2] = copy_journal_identity("journal_gfid_variant", identity);
    variations[2].global_function_id++;
    variations[3] = copy_journal_identity("journal_uid_variant", identity);
    variations[3].function_uid++;
    variations[4] = copy_journal_identity("journal_generation_variant", identity);
    variations[4].generation++;
    variations[5] = copy_journal_identity("journal_reset_variant", identity);
    variations[5].reset_epoch++;
    foreach (variations[i]) begin
      formatted = rdma_cmq_format_batch_key(
        variations[i], 64'h1111_2222_3333_4444,
        64'h5555_6666_7777_8888, 64'h9999_aaaa_bbbb_cccc,
        variation_keys[i], failure_reason
      );
      if (!formatted || failure_reason != "" ||
          variation_keys[i] == expected_key)
        `uvm_error("JOURNAL_KEY_VARIATION",
                   $sformatf("identity variation %0d was not unique", i))
    end
    batch_key = "not-cleared";
    failure_reason = "not-cleared";
    formatted = rdma_cmq_format_batch_key(
      null, 1, 1, 1, batch_key, failure_reason
    );
    if (formatted || batch_key != "" || failure_reason == "")
      `uvm_error("JOURNAL_KEY_INVALID",
                 "invalid formatter input did not fail with cleared output")

    first_engine = rdma_cmq_engine_probe::type_id::create(
      "journal_identity_first_engine"
    );
    second_engine = rdma_cmq_engine_probe::type_id::create(
      "journal_identity_second_engine"
    );
    if (first_engine.journal_engine_instance_id() == 0 ||
        second_engine.journal_engine_instance_id() == 0 ||
        first_engine.journal_engine_instance_id() ==
          second_engine.journal_engine_instance_id())
      `uvm_error("JOURNAL_ENGINE_INSTANCE",
                 "two engine objects did not capture unique nonzero IDs")
    if (first_engine.journal_engine_incarnation() != 0 ||
        first_engine.journal_batch_counter() != 0 ||
        first_engine.journal_attempt_counter() != 0 ||
        first_engine.journal_reset_proof_counter() != 0)
      `uvm_error("JOURNAL_COUNTER_INITIAL",
                 "journal identity counters did not start at zero")
    first_engine.seed_journal_counters(1, 0, 0, 0);
    second_engine.seed_journal_counters(1, 0, 0, 0);
    status = first_engine.allocate_batch_identity_probe(
      identity, batch_key, batch_id
    );
    expect_status("JOURNAL_BATCH_FIRST", status, RDMA_SC_OK);
    status = first_engine.allocate_batch_identity_probe(
      identity, failure_reason, second_batch_id
    );
    expect_status("JOURNAL_BATCH_SECOND", status, RDMA_SC_OK);
    if (batch_id != 1 || second_batch_id != 2 ||
        batch_key == failure_reason)
      `uvm_error("JOURNAL_BATCH_MONOTONIC",
                 "two batch allocations reused an ID or key")
    status = second_engine.allocate_batch_identity_probe(
      identity, failure_reason, second_batch_id
    );
    expect_status("JOURNAL_BATCH_OTHER_ENGINE", status, RDMA_SC_OK);
    if (failure_reason == batch_key)
      `uvm_error("JOURNAL_BATCH_ENGINE_KEY",
                 "different engines generated the same batch key")
    status = first_engine.allocate_attempt_identity_probe(attempt_id);
    expect_status("JOURNAL_ATTEMPT_FIRST", status, RDMA_SC_OK);
    status = first_engine.allocate_attempt_identity_probe(second_attempt_id);
    expect_status("JOURNAL_ATTEMPT_SECOND", status, RDMA_SC_OK);
    status = first_engine.allocate_reset_proof_identity_probe(proof_id);
    expect_status("JOURNAL_PROOF_FIRST", status, RDMA_SC_OK);
    status = first_engine.allocate_reset_proof_identity_probe(second_proof_id);
    expect_status("JOURNAL_PROOF_SECOND", status, RDMA_SC_OK);
    if (attempt_id != 1 || second_attempt_id != 2 || proof_id != 1 ||
        second_proof_id != 2)
      `uvm_error("JOURNAL_AUX_COUNTERS",
                 "attempt/proof IDs were not monotonic nonzero values")

    first_engine.seed_journal_counters(
      1, 64'hffff_ffff_ffff_ffff, 64'hffff_ffff_ffff_ffff,
      64'hffff_ffff_ffff_ffff
    );
    batch_key = "dirty";
    batch_id = 7;
    status = first_engine.allocate_batch_identity_probe(
      identity, batch_key, batch_id
    );
    expect_status("JOURNAL_BATCH_OVERFLOW", status,
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (batch_key != "" || batch_id != 0)
      `uvm_error("JOURNAL_BATCH_OVERFLOW_OUTPUT",
                 "batch overflow published an output")
    attempt_id = 7;
    status = first_engine.allocate_attempt_identity_probe(attempt_id);
    expect_status("JOURNAL_ATTEMPT_OVERFLOW", status,
                  RDMA_SC_RESOURCE_EXHAUSTED);
    proof_id = 7;
    status = first_engine.allocate_reset_proof_identity_probe(proof_id);
    expect_status("JOURNAL_PROOF_OVERFLOW", status,
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (attempt_id != 0 || proof_id != 0)
      `uvm_error("JOURNAL_AUX_OVERFLOW_OUTPUT",
                 "attempt/proof overflow published a wrapped ID")

    lifecycle_engine = rdma_cmq_engine_probe::type_id::create(
      "journal_lifecycle_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("journal_lifecycle_mem");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "journal_lifecycle_scheduler"
    );
    profile = rdma_cmq_test_profile::type_id::create(
      "journal_lifecycle_profile"
    );
    prepared_binding = make_binding(
      "journal_lifecycle_prepared", RDMA_BIND_PREPARED
    );
    active_binding = make_binding(
      "journal_lifecycle_active", RDMA_BIND_ACTIVE
    );
    cmq = make_cmq("journal_lifecycle_cmq", prepared_binding);
    prepare_defaults("JOURNAL_LIFECYCLE_PREPARE", lifecycle_engine, mem,
                     prepared_binding, cmq, scheduler, profile,
                     runtime_desc);
    if (lifecycle_engine.journal_engine_incarnation() != 1)
      `uvm_error("JOURNAL_LIFECYCLE_INC1",
                 "first successful prepare did not publish incarnation 1")
    status = lifecycle_engine.allocate_batch_identity_probe(
      prepared_binding.function_identity_snapshot(), batch_key, batch_id
    );
    expect_status("JOURNAL_LIFECYCLE_BATCH1", status, RDMA_SC_OK);
    status = lifecycle_engine.allocate_attempt_identity_probe(attempt_id);
    expect_status("JOURNAL_LIFECYCLE_ATTEMPT1", status, RDMA_SC_OK);
    status = lifecycle_engine.allocate_reset_proof_identity_probe(proof_id);
    expect_status("JOURNAL_LIFECYCLE_PROOF1", status, RDMA_SC_OK);
    old_incarnation = lifecycle_engine.journal_engine_incarnation();
    lifecycle_engine.reset(reset_completions, status);
    expect_status("JOURNAL_LIFECYCLE_RESET", status, RDMA_SC_OK);
    if (lifecycle_engine.journal_engine_incarnation() != old_incarnation ||
        lifecycle_engine.journal_batch_counter() != batch_id ||
        lifecycle_engine.journal_attempt_counter() != attempt_id ||
        lifecycle_engine.journal_reset_proof_counter() != proof_id)
      `uvm_error("JOURNAL_LIFECYCLE_RESET_COUNTERS",
                 "reset cleared a stable journal identity counter")

    next_prepared = make_binding(
      "journal_lifecycle_next_prepared", RDMA_BIND_PREPARED
    );
    next_active = make_binding(
      "journal_lifecycle_next_active", RDMA_BIND_ACTIVE
    );
    next_prepared.generation++;
    status = next_prepared.synchronize_identity_from_legacy_mirrors();
    expect_status("JOURNAL_LIFECYCLE_NEXT_PREPARED_ID", status, RDMA_SC_OK);
    next_prepared.owner_h = next_prepared.make_handle();
    next_active.generation++;
    status = next_active.synchronize_identity_from_legacy_mirrors();
    expect_status("JOURNAL_LIFECYCLE_NEXT_ACTIVE_ID", status, RDMA_SC_OK);
    next_active.owner_h = next_active.make_handle();
    next_cmq = make_cmq("journal_lifecycle_next_cmq", next_prepared);
    prepare_defaults("JOURNAL_LIFECYCLE_REPREPARE", lifecycle_engine, mem,
                     next_prepared, next_cmq, scheduler, profile,
                     runtime_desc);
    lifecycle_engine.activate(next_active, status);
    expect_status("JOURNAL_LIFECYCLE_ACTIVATE", status, RDMA_SC_OK);
    if (lifecycle_engine.journal_engine_incarnation() !=
        old_incarnation + 1'b1)
      `uvm_error("JOURNAL_LIFECYCLE_INC2",
                 "successful reprepare did not advance incarnation")
    status = lifecycle_engine.allocate_batch_identity_probe(
      next_active.function_identity_snapshot(), failure_reason,
      second_batch_id
    );
    expect_status("JOURNAL_LIFECYCLE_BATCH2", status, RDMA_SC_OK);
    status = lifecycle_engine.allocate_attempt_identity_probe(
      second_attempt_id
    );
    expect_status("JOURNAL_LIFECYCLE_ATTEMPT2", status, RDMA_SC_OK);
    status = lifecycle_engine.allocate_reset_proof_identity_probe(
      second_proof_id
    );
    expect_status("JOURNAL_LIFECYCLE_PROOF2", status, RDMA_SC_OK);
    if (second_batch_id <= batch_id || second_attempt_id <= attempt_id ||
        second_proof_id <= proof_id || failure_reason == batch_key)
      `uvm_error("JOURNAL_LIFECYCLE_MONOTONIC",
                 "reprepare reused a stable journal identity")
    lifecycle_engine.shutdown(status);
    expect_status("JOURNAL_LIFECYCLE_SHUTDOWN", status, RDMA_SC_OK);

    overflow_engine = rdma_cmq_engine_probe::type_id::create(
      "journal_prepare_overflow_engine"
    );
    overflow_engine.seed_journal_counters(
      64'hffff_ffff_ffff_ffff, 0, 0, 0
    );
    overflow_mem = rdma_mock_host_mem::type_id::create(
      "journal_prepare_overflow_mem"
    );
    overflow_scheduler = rdma_doorbell_scheduler::type_id::create(
      "journal_prepare_overflow_scheduler"
    );
    overflow_profile = rdma_cmq_test_profile::type_id::create(
      "journal_prepare_overflow_profile"
    );
    overflow_binding = make_binding(
      "journal_prepare_overflow_binding", RDMA_BIND_PREPARED
    );
    overflow_cmq = make_cmq(
      "journal_prepare_overflow_cmq", overflow_binding
    );
    overflow_engine.prepare(
      overflow_binding, overflow_cmq, 1'b1, 20'h34567, overflow_mem,
      overflow_scheduler, overflow_profile, runtime_desc, status
    );
    expect_status("JOURNAL_PREPARE_OVERFLOW", status,
                  RDMA_SC_RESOURCE_EXHAUSTED);
    if (runtime_desc != null || overflow_mem.calls.size() != 0 ||
        overflow_engine.state() != RDMA_CMQ_ENGINE_UNCONFIGURED ||
        overflow_engine.journal_engine_incarnation() !=
          64'hffff_ffff_ffff_ffff)
      `uvm_error("JOURNAL_PREPARE_OVERFLOW_EFFECT",
                 "incarnation overflow performed I/O or changed state")
  endtask

  // 功能：在 storage fixture 安装前逐项验证 candidate 的完整 mutable-evidence invariant。
  // 输入/输出及副作用：engine/record/preallocated 为调用方持有的非拥有输入；本 task
  //   临时注入 enum、reducer、recovery、owner 与 completion 故障，并在每次断言后恢复。
  // 失败/边界：每个 candidate 必须返回 INVALID_ARGUMENT 且四张 retained 表保持空；
  //   fixture 不完整时报告 UVM_ERROR 并返回，不负责 prepare、安装、删除或 shutdown。
  task automatic check_journal_candidate_mutable_evidence_invariants(
    rdma_cmq_engine_probe engine,
    rdma_cmq_batch_submission_record record,
    rdma_cmq_preallocated_publish_batch preallocated
  );
    rdma_cmq_nonfatal_snapshot_context snapshot_context;
    rdma_cmq_ticket detached_ticket;
    rdma_cmq_completion saved_completion;
    rdma_status detached_status;
    string failure_reason;

    if (engine == null || record == null || preallocated == null ||
        record.items.size() == 0 || record.items[0] == null) begin
      `uvm_error("JOURNAL_CANDIDATE_FIXTURE_OUTPUT",
                 "candidate mutable-evidence fixture is incomplete")
      return;
    end

    snapshot_context = new();
    if (!snapshot_context.try_snapshot_optional_ticket(
          record.items[0].ticket, detached_ticket, failure_reason
        ) || detached_ticket == null ||
        !snapshot_context.try_snapshot_required_status(
          record.items[0].status, detached_status, failure_reason
        ) || detached_status == null) begin
      `uvm_error("JOURNAL_CANDIDATE_DETACHED_VALUES", failure_reason)
      return;
    end

    record.state = rdma_cmq_submission_state_e'(4'hf);
    expect_candidate_journal_rejection(
      "JOURNAL_CANDIDATE_BATCH_STATE_ENUM", engine, record, preallocated
    );
    record.state = RDMA_CMQ_SUBMISSION_COMPLETED;
    record.submission_effect = rdma_submission_effect_e'(3'b111);
    expect_candidate_journal_rejection(
      "JOURNAL_CANDIDATE_BATCH_EFFECT_ENUM", engine, record, preallocated
    );
    record.submission_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    record.attempt_effect = rdma_submission_effect_e'(3'b111);
    expect_candidate_journal_rejection(
      "JOURNAL_CANDIDATE_BATCH_ATTEMPT_EFFECT_ENUM", engine, record,
      preallocated
    );
    record.attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    record.items[0].state = rdma_cmq_submission_state_e'(4'hf);
    expect_candidate_journal_rejection(
      "JOURNAL_CANDIDATE_ITEM_STATE_ENUM", engine, record, preallocated
    );
    record.items[0].state = RDMA_CMQ_SUBMISSION_COMPLETED;
    record.items[0].submission_effect = rdma_submission_effect_e'(3'b111);
    expect_candidate_journal_rejection(
      "JOURNAL_CANDIDATE_ITEM_EFFECT_ENUM", engine, record, preallocated
    );
    record.items[0].submission_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    record.items[0].attempt_effect = rdma_submission_effect_e'(3'b111);
    expect_candidate_journal_rejection(
      "JOURNAL_CANDIDATE_ATTEMPT_EFFECT_ENUM", engine, record, preallocated
    );
    record.items[0].attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    record.items[0].completion_phase = rdma_cmq_completion_phase_e'(3'b111);
    expect_candidate_journal_rejection(
      "JOURNAL_CANDIDATE_PHASE_ENUM", engine, record, preallocated
    );
    record.items[0].completion_phase = RDMA_CMQ_COMPLETION_TERMINAL;
    record.state = RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED;
    expect_candidate_journal_rejection(
      "JOURNAL_CANDIDATE_BATCH_REDUCTION", engine, record, preallocated
    );
    record.state = RDMA_CMQ_SUBMISSION_COMPLETED;
    record.items[0].recovery_required = 1'b1;
    expect_candidate_journal_rejection(
      "JOURNAL_CANDIDATE_RECOVERY_CLASSIFIER", engine, record, preallocated
    );
    record.items[0].recovery_required = 1'b0;
    record.attempt_id++;
    preallocated.attempt_id++;
    expect_candidate_journal_rejection(
      "JOURNAL_CANDIDATE_OWNER_ATTEMPT", engine, record, preallocated
    );
    record.attempt_id--;
    preallocated.attempt_id--;
    saved_completion = record.items[0].completion;
    record.items[0].completion = null;
    expect_candidate_journal_rejection(
      "JOURNAL_CANDIDATE_REQUIRED_COMPLETION", engine, record,
      preallocated
    );
    record.items[0].completion = saved_completion;
    record.items[0].completion.ticket = detached_ticket;
    expect_candidate_journal_rejection(
      "JOURNAL_CANDIDATE_COMPLETION_TICKET_ALIAS", engine, record,
      preallocated
    );
    record.items[0].completion.ticket = record.items[0].ticket;
    record.items[0].completion.status = detached_status;
    expect_candidate_journal_rejection(
      "JOURNAL_CANDIDATE_COMPLETION_STATUS_ALIAS", engine, record,
      preallocated
    );
    record.items[0].completion.status = record.items[0].status;
  endtask

  // 功能：在 storage fixture 已安装期间逐项验证 retained mutable-evidence invariant。
  // 输入/输出及副作用：engine/record 为调用方持有的非拥有输入；通过 fault reference
  //   临时破坏 enum、reducer、recovery、owner、completion 与 ticket，并逐项恢复原值。
  // 失败/边界：batch/ticket API 对每个 corruption 必须返回 INVALID_STATE/null；缺少
  //   retained record 时报告 UVM_ERROR 并返回，不删除 journal 或关闭共享 engine。
  task automatic check_journal_stored_mutable_evidence_invariants(
    rdma_cmq_engine_probe engine,
    rdma_cmq_batch_submission_record record
  );
    rdma_cmq_batch_submission_record stored;
    rdma_cmq_nonfatal_snapshot_context snapshot_context;
    rdma_cmq_ticket detached_ticket;
    rdma_cmq_ticket stored_ticket;
    rdma_cmq_completion saved_completion;
    rdma_status detached_status;
    rdma_function_handle saved_function;
    string failure_reason;
    longint unsigned saved_sequence;

    if (engine == null || record == null || record.items.size() == 0 ||
        record.items[0] == null) begin
      `uvm_error("JOURNAL_STORED_FIXTURE_OUTPUT",
                 "stored mutable-evidence fixture is incomplete")
      return;
    end
    snapshot_context = new();
    if (!snapshot_context.try_snapshot_optional_ticket(
          record.items[0].ticket, detached_ticket, failure_reason
        ) || detached_ticket == null ||
        !snapshot_context.try_snapshot_required_status(
          record.items[0].status, detached_status, failure_reason
        ) || detached_status == null) begin
      `uvm_error("JOURNAL_STORED_DETACHED_VALUES", failure_reason)
      return;
    end
    stored = engine.journal_record_fault_reference(record.batch_key);
    if (stored == null) begin
      `uvm_error("JOURNAL_STORED_REFERENCE",
                 "valid storage record did not install")
      return;
    end

    stored.state = rdma_cmq_submission_state_e'(4'hf);
    expect_stored_journal_rejection(
      "JOURNAL_STORED_BATCH_STATE_ENUM", engine, record.batch_key,
      record.items[0].ticket
    );
    stored.state = RDMA_CMQ_SUBMISSION_COMPLETED;
    stored.submission_effect = rdma_submission_effect_e'(3'b111);
    expect_stored_journal_rejection(
      "JOURNAL_STORED_BATCH_EFFECT_ENUM", engine, record.batch_key,
      record.items[0].ticket
    );
    stored.submission_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    stored.attempt_effect = rdma_submission_effect_e'(3'b111);
    expect_stored_journal_rejection(
      "JOURNAL_STORED_BATCH_ATTEMPT_EFFECT_ENUM", engine, record.batch_key,
      record.items[0].ticket
    );
    stored.attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    stored.items[0].state = rdma_cmq_submission_state_e'(4'hf);
    expect_stored_journal_rejection(
      "JOURNAL_STORED_ITEM_STATE_ENUM", engine, record.batch_key,
      record.items[0].ticket
    );
    stored.items[0].state = RDMA_CMQ_SUBMISSION_COMPLETED;
    stored.items[0].submission_effect = rdma_submission_effect_e'(3'b111);
    expect_stored_journal_rejection(
      "JOURNAL_STORED_ITEM_EFFECT_ENUM", engine, record.batch_key,
      record.items[0].ticket
    );
    stored.items[0].submission_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    stored.items[0].attempt_effect = rdma_submission_effect_e'(3'b111);
    expect_stored_journal_rejection(
      "JOURNAL_STORED_ATTEMPT_EFFECT_ENUM", engine, record.batch_key,
      record.items[0].ticket
    );
    stored.items[0].attempt_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    stored.items[0].completion_phase = rdma_cmq_completion_phase_e'(3'b111);
    expect_stored_journal_rejection(
      "JOURNAL_STORED_PHASE_ENUM", engine, record.batch_key,
      record.items[0].ticket
    );
    stored.items[0].completion_phase = RDMA_CMQ_COMPLETION_TERMINAL;

    stored.state = RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED;
    expect_stored_journal_rejection(
      "JOURNAL_STORED_BATCH_REDUCTION", engine, record.batch_key,
      record.items[0].ticket
    );
    stored.state = RDMA_CMQ_SUBMISSION_COMPLETED;

    stored.items[0].recovery_required = 1'b1;
    expect_stored_journal_rejection(
      "JOURNAL_STORED_RECOVERY_CLASSIFIER", engine, record.batch_key,
      record.items[0].ticket
    );
    stored.items[0].recovery_required = 1'b0;
    stored.items[0].recovery_owner.admission_attempt_id = stored.attempt_id + 1'b1;
    expect_stored_journal_rejection(
      "JOURNAL_STORED_OWNER_ATTEMPT", engine, record.batch_key,
      record.items[0].ticket
    );
    stored.items[0].recovery_owner.admission_attempt_id = record.attempt_id;
    saved_completion = stored.items[0].completion;
    stored.items[0].completion = null;
    expect_stored_journal_rejection(
      "JOURNAL_STORED_REQUIRED_COMPLETION", engine, record.batch_key,
      record.items[0].ticket
    );
    stored.items[0].completion = saved_completion;
    stored.items[0].completion.ticket = detached_ticket;
    expect_stored_journal_rejection(
      "JOURNAL_STORED_COMPLETION_TICKET_ALIAS", engine, record.batch_key,
      record.items[0].ticket
    );
    stored.items[0].completion.ticket = stored.items[0].ticket;
    stored.items[0].completion.status = detached_status;
    expect_stored_journal_rejection(
      "JOURNAL_STORED_COMPLETION_STATUS_ALIAS", engine, record.batch_key,
      record.items[0].ticket
    );
    stored.items[0].completion.status = stored.items[0].status;

    // slot_sequence 增加两个完整 ring 周期仍保持 sq_index/wrap shape 合法，且不
    // 改变 command_key；两 API 必须先发现 retained full-value drift，而非信任索引。
    stored_ticket = stored.items[0].ticket;
    saved_sequence = stored_ticket.slot_sequence;
    stored_ticket.slot_sequence = saved_sequence + 64;
    expect_stored_journal_rejection(
      "JOURNAL_STORED_TICKET_NONKEY", engine, record.batch_key,
      record.items[0].ticket
    );
    stored_ticket.slot_sequence = saved_sequence;
    stored_ticket = null;

    // null Function 使 retained ticket shape 无法安全形成 key；batch/ticket API 均须
    // 在 caller full-value compare 前返回 INVALID_STATE，且故障窗口后恢复原 handle。
    stored_ticket = stored.items[0].ticket;
    saved_function = stored_ticket.function_h;
    stored_ticket.function_h = null;
    expect_stored_journal_rejection(
      "JOURNAL_STORED_TICKET_NULL_FUNCTION", engine, record.batch_key,
      record.items[0].ticket
    );
    stored_ticket.function_h = saved_function;
    saved_function = null;
    stored_ticket = null;
  endtask

  // 功能：复用已清空的 storage fixture，验证四类单行 orphan 先于正常分类被识别。
  // 输入/输出及副作用：engine/profile_service/identity/record/preallocated 为非拥有输入；
  //   逐次只播种一张 retained 表，并精确保存、临时回拨和恢复四个 identity counter。
  // 失败/边界：播种/清理失败、非 INVALID_STATE、partial output 或窗口间残留均报告
  //   UVM_ERROR；输入 graph 不完整时直接返回，不负责删除合法行或 shutdown。
  task automatic check_journal_orphan_row_invariants(
    rdma_cmq_engine_probe engine,
    rdma_cmq_journal_tracking_profile profile_service,
    rdma_function_identity identity,
    rdma_cmq_batch_submission_record record,
    rdma_cmq_preallocated_publish_batch preallocated
  );
    rdma_cmq_batch_submission_record snapshot;
    rdma_status status;
    string batch_key;
    string allocated_key;
    longint unsigned allocated_id;
    longint unsigned saved_incarnation;
    longint unsigned saved_batch_id;
    longint unsigned saved_attempt_id;
    longint unsigned saved_proof_id;

    if (engine == null || profile_service == null || identity == null ||
        record == null || preallocated == null || record.batch_key.len() == 0 ||
        record.batch_id == 0 || record.engine_incarnation == 0 ||
        record.items.size() == 0 || record.items[0] == null ||
        record.items[0].ticket == null) begin
      `uvm_error("JOURNAL_ORPHAN_FIXTURE_OUTPUT",
                 "orphan fixture is incomplete")
      return;
    end
    batch_key = record.batch_key;
    saved_incarnation = engine.journal_engine_incarnation();
    saved_batch_id = engine.journal_batch_counter();
    saved_attempt_id = engine.journal_attempt_counter();
    saved_proof_id = engine.journal_reset_proof_counter();

    if (!engine.seed_journal_orphan(
          RDMA_CMQ_TEST_JOURNAL_ORPHAN_PROFILE, batch_key, null, null,
          profile_service, null
        ))
      `uvm_error("JOURNAL_ORPHAN_PROFILE_SEED", "profile orphan was not seeded")
    engine.seed_journal_counters(
      record.engine_incarnation, record.batch_id - 1'b1,
      saved_attempt_id, saved_proof_id
    );
    status = engine.allocate_batch_identity_probe(
      identity, allocated_key, allocated_id
    );
    engine.seed_journal_counters(
      saved_incarnation, saved_batch_id, saved_attempt_id, saved_proof_id
    );
    expect_status("JOURNAL_ORPHAN_PROFILE_ALLOCATE", status,
                  RDMA_SC_INVALID_STATE);
    if (allocated_key != "" || allocated_id != 0)
      `uvm_error("JOURNAL_ORPHAN_PROFILE_ALLOCATE_OUTPUT",
                 "profile orphan allocation published an identity")
    engine.query_submission_journal(batch_key, snapshot, status);
    expect_status("JOURNAL_ORPHAN_PROFILE_QUERY", status,
                  RDMA_SC_INVALID_STATE);
    status = engine.remove_submission_journal_probe(batch_key);
    expect_status("JOURNAL_ORPHAN_PROFILE_REMOVE", status,
                  RDMA_SC_INVALID_STATE);
    if (snapshot != null || !engine.clear_journal_orphan(
          RDMA_CMQ_TEST_JOURNAL_ORPHAN_PROFILE, batch_key, null
        ))
      `uvm_error("JOURNAL_ORPHAN_PROFILE_CLEAN",
                 "profile orphan query escaped or cleanup failed")
    if (!engine.seed_journal_orphan(
          RDMA_CMQ_TEST_JOURNAL_ORPHAN_PREALLOCATION, batch_key, null,
          preallocated, null, null
        ))
      `uvm_error("JOURNAL_ORPHAN_PREALLOC_SEED",
                 "preallocation orphan was not seeded")
    status = engine.install_submission_journal_probe(record, preallocated);
    expect_status("JOURNAL_ORPHAN_PREALLOC_INSTALL", status,
                  RDMA_SC_INVALID_STATE);
    engine.query_submission_journal(batch_key, snapshot, status);
    expect_status("JOURNAL_ORPHAN_PREALLOC_QUERY", status,
                  RDMA_SC_INVALID_STATE);
    status = engine.remove_submission_journal_probe(batch_key);
    expect_status("JOURNAL_ORPHAN_PREALLOC_REMOVE", status,
                  RDMA_SC_INVALID_STATE);
    if (snapshot != null || !engine.clear_journal_orphan(
          RDMA_CMQ_TEST_JOURNAL_ORPHAN_PREALLOCATION, batch_key, null
        ))
      `uvm_error("JOURNAL_ORPHAN_PREALLOC_CLEAN",
                 "preallocation orphan query escaped or cleanup failed")

    if (!engine.seed_journal_orphan(
          RDMA_CMQ_TEST_JOURNAL_ORPHAN_RECORD, batch_key, record, null,
          null, null
        ))
      `uvm_error("JOURNAL_ORPHAN_RECORD_SEED", "record orphan was not seeded")
    engine.query_submission_journal(batch_key, snapshot, status);
    expect_status("JOURNAL_ORPHAN_RECORD_QUERY", status,
                  RDMA_SC_INVALID_STATE);
    status = engine.remove_submission_journal_probe(batch_key);
    expect_status("JOURNAL_ORPHAN_RECORD_REMOVE", status,
                  RDMA_SC_INVALID_STATE);
    if (snapshot != null || !engine.clear_journal_orphan(
          RDMA_CMQ_TEST_JOURNAL_ORPHAN_RECORD, batch_key, null
        ))
      `uvm_error("JOURNAL_ORPHAN_RECORD_CLEAN",
                 "record orphan query escaped or cleanup failed")

    if (!engine.seed_journal_orphan(
          RDMA_CMQ_TEST_JOURNAL_ORPHAN_TICKET_INDEX, batch_key, null, null,
          null, record.items[0].ticket
        ))
      `uvm_error("JOURNAL_ORPHAN_TICKET_SEED", "ticket orphan was not seeded")
    engine.query_submission_journal(batch_key, snapshot, status);
    expect_status("JOURNAL_ORPHAN_TICKET_BATCH_QUERY", status,
                  RDMA_SC_INVALID_STATE);
    engine.query_submission_journal_by_ticket(
      record.items[0].ticket, snapshot, status
    );
    expect_status("JOURNAL_ORPHAN_TICKET_QUERY", status,
                  RDMA_SC_INVALID_STATE);
    status = engine.remove_submission_journal_probe(batch_key);
    expect_status("JOURNAL_ORPHAN_TICKET_REMOVE", status,
                  RDMA_SC_INVALID_STATE);
    if (snapshot != null || !engine.clear_journal_orphan(
          RDMA_CMQ_TEST_JOURNAL_ORPHAN_TICKET_INDEX, batch_key,
          record.items[0].ticket
        ))
      `uvm_error("JOURNAL_ORPHAN_TICKET_CLEAN",
                 "ticket orphan query escaped or cleanup failed")

    if (engine.submission_journal_count() != 0 ||
        engine.journal_ticket_index_count() != 0 ||
        engine.preallocated_publish_batch_count() != 0 ||
        engine.journal_profile_count() != 0)
      `uvm_error("JOURNAL_ORPHAN_FINAL_COUNTS",
                 "orphan fault windows mutated another retained row")
  endtask

  // 功能：用单一 storage fixture 验证 mutable/orphan invariant、四表原子生命周期、
  //   detached query、fence/digest 重验及 reset/reprepare 后旧 ticket 的诊断可用性。
  // 输入/输出及副作用：无参数；profile A 的同一 record 依次承载 candidate、stored、
  //   lifecycle 与 orphan 窗口，再以同名不同语义 profile B 激活新 incarnation。
  // 失败/边界：candidate/collision 必须原子拒绝，stored/orphan corruption 必须
  //   INVALID_STATE/null；每个故障恢复后才复用 graph，末尾清空四表并 shutdown。
  task automatic check_submission_journal_storage_and_queries();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_cmq_journal_tracking_profile profile_a;
    rdma_cmq_journal_tracking_profile profile_b;
    rdma_function_binding prepared_binding;
    rdma_function_binding next_prepared;
    rdma_function_binding next_active;
    rdma_function_identity identity;
    rdma_cmq cmq;
    rdma_cmq next_cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_batch_submission_record record;
    rdma_cmq_batch_submission_record snapshot;
    rdma_cmq_batch_submission_record second_snapshot;
    rdma_cmq_batch_submission_record candidate;
    rdma_cmq_preallocated_publish_batch preallocated;
    rdma_cmq_preallocated_publish_batch candidate_preallocated;
    rdma_cmq_ticket old_ticket;
    rdma_cmq_completion reset_completions[$];
    rdma_hw_model saved_body;
    rdma_cmq_unknown_body unknown_body;
    rdma_status status;
    string batch_key;
    longint unsigned batch_id;
    longint unsigned attempt_id;
    int unsigned profile_a_calls;
    int unsigned profile_b_calls;
    bit fence_active;
    string fence_key;
    string fence_reason;

    engine = rdma_cmq_engine_probe::type_id::create(
      "submission_journal_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("submission_journal_mem");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "submission_journal_scheduler"
    );
    profile_a = rdma_cmq_journal_tracking_profile::type_id::create(
      "submission_journal_profile_a"
    );
    prepared_binding = make_binding(
      "submission_journal_prepared", RDMA_BIND_PREPARED
    );
    cmq = make_cmq("submission_journal_cmq", prepared_binding);
    engine.prepare(
      prepared_binding, cmq, 1'b1, 20'h34567, mem, scheduler, profile_a,
      runtime_desc, status
    );
    expect_status("JOURNAL_STORAGE_PREPARE", status, RDMA_SC_OK);
    status = prepared_binding.snapshot_identity_nonfatal(identity);
    expect_status("JOURNAL_STORAGE_IDENTITY", status, RDMA_SC_OK);
    status = engine.allocate_batch_identity_probe(
      identity, batch_key, batch_id
    );
    expect_status("JOURNAL_STORAGE_BATCH", status, RDMA_SC_OK);
    status = engine.allocate_attempt_identity_probe(attempt_id);
    expect_status("JOURNAL_STORAGE_ATTEMPT", status, RDMA_SC_OK);
    status = build_journal_fixture(
      "submission_journal", engine, profile_a, prepared_binding, cmq,
      batch_key, batch_id, attempt_id, 64'h1000,
      RDMA_CMQ_TEST_JOURNAL_BODY_OBJECT_ID, record, preallocated
    );
    expect_status("JOURNAL_STORAGE_FIXTURE", status, RDMA_SC_OK);
    if (record == null || preallocated == null) begin
      `uvm_error("JOURNAL_STORAGE_FIXTURE",
                 "complete fixture builder returned null outputs")
      engine.shutdown(status);
      return;
    end
    old_ticket = record.items[0].ticket;

    snapshot = record;
    engine.query_submission_journal("missing-batch", snapshot, status);
    expect_status("JOURNAL_QUERY_MISSING", status,
                  RDMA_SC_INVALID_ARGUMENT);
    if (snapshot != null)
      `uvm_error("JOURNAL_QUERY_MISSING_OUTPUT",
                 "missing batch query retained caller output")
    engine.query_submission_fence(
      fence_active, fence_key, fence_reason, status
    );
    expect_status("JOURNAL_FENCE_EMPTY", status, RDMA_SC_OK);
    if (fence_active || fence_key != "" || fence_reason != "")
      `uvm_error("JOURNAL_FENCE_EMPTY_VALUE",
                 "empty fence query published a partial fence")

    check_journal_candidate_mutable_evidence_invariants(
      engine, record, preallocated
    );
    status = engine.install_submission_journal_probe(record, preallocated);
    expect_status("JOURNAL_INSTALL", status, RDMA_SC_OK);
    if (engine.submission_journal_count() != 1 ||
        engine.journal_ticket_index_count() != 2 ||
        engine.preallocated_publish_batch_count() != 1 ||
        engine.journal_profile_count() != 1 ||
        !engine.journal_profile_matches(batch_key, profile_a))
      `uvm_error("JOURNAL_INSTALL_COUNTS",
                 "journal rows/profile service were not atomically installed")
    check_journal_stored_mutable_evidence_invariants(engine, record);

    status = engine.install_submission_journal_probe(record, preallocated);
    expect_status("JOURNAL_DUPLICATE_BATCH", status,
                  RDMA_SC_RESOURCE_BUSY);
    if (engine.submission_journal_count() != 1 ||
        engine.journal_ticket_index_count() != 2 ||
        engine.preallocated_publish_batch_count() != 1 ||
        engine.journal_profile_count() != 1)
      `uvm_error("JOURNAL_DUPLICATE_BATCH_ATOMIC",
                 "duplicate batch changed one or more journal tables")

    engine.query_submission_journal(batch_key, snapshot, status);
    expect_status("JOURNAL_QUERY_BATCH", status, RDMA_SC_OK);
    expect_journal_snapshot(
      "JOURNAL_QUERY_BATCH_GRAPH", engine, profile_a, snapshot, record
    );
    mutate_journal_snapshot(snapshot);
    engine.query_submission_journal_by_ticket(
      record.items[0].ticket, snapshot, status
    );
    expect_status("JOURNAL_QUERY_TICKET0", status, RDMA_SC_OK);
    expect_journal_snapshot(
      "JOURNAL_QUERY_TICKET0_GRAPH", engine, profile_a, snapshot, record
    );
    mutate_journal_snapshot(snapshot);
    engine.query_submission_journal_by_ticket(
      record.items[1].ticket, snapshot, status
    );
    expect_status("JOURNAL_QUERY_TICKET1", status, RDMA_SC_OK);
    expect_journal_snapshot(
      "JOURNAL_QUERY_TICKET1_GRAPH", engine, profile_a, snapshot, record
    );
    mutate_journal_snapshot(snapshot);
    engine.query_submission_journal(batch_key, second_snapshot, status);
    expect_status("JOURNAL_QUERY_AFTER_MUTATION", status, RDMA_SC_OK);
    expect_journal_snapshot(
      "JOURNAL_QUERY_AFTER_MUTATION_GRAPH", engine, profile_a,
      second_snapshot, record
    );
    if (second_snapshot == snapshot)
      `uvm_error("JOURNAL_QUERY_FRESH_OUTER",
                 "two queries reused the same outer snapshot")

    status = engine.allocate_batch_identity_probe(
      identity, batch_key, batch_id
    );
    expect_status("JOURNAL_COLLISION_BATCH", status, RDMA_SC_OK);
    status = engine.allocate_attempt_identity_probe(attempt_id);
    expect_status("JOURNAL_COLLISION_ATTEMPT", status, RDMA_SC_OK);
    status = build_journal_fixture(
      "submission_journal_ticket_collision", engine, profile_a,
      prepared_binding, cmq, batch_key, batch_id, attempt_id, 64'h1000,
      RDMA_CMQ_TEST_JOURNAL_BODY_OBJECT_ID, candidate,
      candidate_preallocated
    );
    expect_status("JOURNAL_COLLISION_FIXTURE", status, RDMA_SC_OK);
    status = engine.install_submission_journal_probe(
      candidate, candidate_preallocated
    );
    expect_status("JOURNAL_DUPLICATE_TICKET", status,
                  RDMA_SC_RESOURCE_BUSY);
    if (engine.submission_journal_count() != 1 ||
        engine.journal_ticket_index_count() != 2 ||
        engine.preallocated_publish_batch_count() != 1 ||
        engine.journal_profile_count() != 1)
      `uvm_error("JOURNAL_DUPLICATE_TICKET_ATOMIC",
                 "ticket collision left a partial journal row")

    status = engine.allocate_batch_identity_probe(
      identity, batch_key, batch_id
    );
    expect_status("JOURNAL_CARDINALITY_BATCH", status, RDMA_SC_OK);
    status = engine.allocate_attempt_identity_probe(attempt_id);
    expect_status("JOURNAL_CARDINALITY_ATTEMPT", status, RDMA_SC_OK);
    status = build_journal_fixture(
      "submission_journal_cardinality", engine, profile_a,
      prepared_binding, cmq, batch_key, batch_id, attempt_id, 64'h2000,
      RDMA_CMQ_TEST_JOURNAL_BODY_OBJECT_ID, candidate,
      candidate_preallocated
    );
    expect_status("JOURNAL_CARDINALITY_FIXTURE", status, RDMA_SC_OK);
    void'(candidate_preallocated.items.pop_back());
    status = engine.install_submission_journal_probe(
      candidate, candidate_preallocated
    );
    expect_status("JOURNAL_CARDINALITY", status, RDMA_SC_INVALID_ARGUMENT);

    status = engine.allocate_batch_identity_probe(
      identity, batch_key, batch_id
    );
    expect_status("JOURNAL_PARTIAL_BATCH", status, RDMA_SC_OK);
    status = engine.allocate_attempt_identity_probe(attempt_id);
    expect_status("JOURNAL_PARTIAL_ATTEMPT", status, RDMA_SC_OK);
    status = build_journal_fixture(
      "submission_journal_partial", engine, profile_a, prepared_binding,
      cmq, batch_key, batch_id, attempt_id, 64'h3000,
      RDMA_CMQ_TEST_JOURNAL_BODY_OBJECT_ID, candidate,
      candidate_preallocated
    );
    expect_status("JOURNAL_PARTIAL_FIXTURE", status, RDMA_SC_OK);
    candidate_preallocated.items[1].slot_record = null;
    status = engine.install_submission_journal_probe(
      candidate, candidate_preallocated
    );
    expect_status("JOURNAL_PARTIAL_PREALLOC", status,
                  RDMA_SC_INVALID_ARGUMENT);

    status = engine.allocate_batch_identity_probe(
      identity, batch_key, batch_id
    );
    expect_status("JOURNAL_UNKNOWN_BODY_BATCH", status, RDMA_SC_OK);
    status = engine.allocate_attempt_identity_probe(attempt_id);
    expect_status("JOURNAL_UNKNOWN_BODY_ATTEMPT", status, RDMA_SC_OK);
    status = build_journal_fixture(
      "submission_journal_unknown_candidate", engine, profile_a,
      prepared_binding, cmq, batch_key, batch_id, attempt_id, 64'h4000,
      RDMA_CMQ_TEST_JOURNAL_BODY_OBJECT_ID, candidate,
      candidate_preallocated
    );
    expect_status("JOURNAL_UNKNOWN_BODY_FIXTURE", status, RDMA_SC_OK);
    unknown_body = new("submission_journal_unknown_candidate_body");
    candidate.items[0].command.body = unknown_body;
    status = engine.install_submission_journal_probe(
      candidate, candidate_preallocated
    );
    expect_status("JOURNAL_UNKNOWN_BODY_CANDIDATE", status,
                  RDMA_SC_INVALID_ARGUMENT);
    if (engine.submission_journal_count() != 1 ||
        engine.journal_ticket_index_count() != 2 ||
        engine.preallocated_publish_batch_count() != 1 ||
        engine.journal_profile_count() != 1)
      `uvm_error("JOURNAL_REJECTION_ATOMIC",
                 "candidate rejection changed a journal table")

    status = engine.allocate_batch_identity_probe(
      identity, batch_key, batch_id
    );
    expect_status("JOURNAL_REMOVE_BATCH", status, RDMA_SC_OK);
    status = engine.allocate_attempt_identity_probe(attempt_id);
    expect_status("JOURNAL_REMOVE_ATTEMPT", status, RDMA_SC_OK);
    status = build_journal_fixture(
      "submission_journal_remove", engine, profile_a, prepared_binding,
      cmq, batch_key, batch_id, attempt_id, 64'h5000,
      RDMA_CMQ_TEST_JOURNAL_BODY_OBJECT_ID, candidate,
      candidate_preallocated
    );
    expect_status("JOURNAL_REMOVE_FIXTURE", status, RDMA_SC_OK);
    status = engine.install_submission_journal_probe(
      candidate, candidate_preallocated
    );
    expect_status("JOURNAL_REMOVE_INSTALL", status, RDMA_SC_OK);
    if (engine.submission_journal_count() != 2 ||
        engine.journal_ticket_index_count() != 4 ||
        engine.preallocated_publish_batch_count() != 2 ||
        engine.journal_profile_count() != 2)
      `uvm_error("JOURNAL_REMOVE_INSTALL_COUNTS",
                 "second valid record did not install all rows")
    status = engine.remove_submission_journal_probe(batch_key);
    expect_status("JOURNAL_REMOVE", status, RDMA_SC_OK);
    if (engine.submission_journal_count() != 1 ||
        engine.journal_ticket_index_count() != 2 ||
        engine.preallocated_publish_batch_count() != 1 ||
        engine.journal_profile_count() != 1)
      `uvm_error("JOURNAL_REMOVE_COUNTS",
                 "remove did not delete record/index/preallocation/profile")
    status = engine.remove_submission_journal_probe("missing-batch");
    expect_status("JOURNAL_REMOVE_MISSING", status,
                  RDMA_SC_INVALID_ARGUMENT);

    engine.seed_submission_fence(record.batch_key, "publication uncertain");
    engine.query_submission_fence(
      fence_active, fence_key, fence_reason, status
    );
    expect_status("JOURNAL_FENCE_ACTIVE", status, RDMA_SC_OK);
    if (!fence_active || fence_key != record.batch_key ||
        fence_reason != "publication uncertain")
      `uvm_error("JOURNAL_FENCE_ACTIVE_VALUE",
                 "fence query changed its exact key or reason")

    profile_a.advertised_name = "rdma-name-drift";
    engine.query_submission_journal(record.batch_key, snapshot, status);
    expect_status("JOURNAL_PROFILE_NAME_DRIFT", status,
                  RDMA_SC_INVALID_STATE);
    if (snapshot != null)
      `uvm_error("JOURNAL_PROFILE_NAME_DRIFT_OUTPUT",
                 "name-drift query published a record")
    profile_a.advertised_name = "rdma";
    if (!engine.drop_journal_profile(record.batch_key))
      `uvm_error("JOURNAL_PROFILE_DROP", "profile row was not present")
    engine.query_submission_journal(record.batch_key, snapshot, status);
    expect_status("JOURNAL_PROFILE_MISSING", status,
                  RDMA_SC_INVALID_STATE);
    if (snapshot != null ||
        !engine.restore_journal_profile(record.batch_key, profile_a))
      `uvm_error("JOURNAL_PROFILE_MISSING_OUTPUT",
                 "missing profile query escaped or restore failed")
    profile_a.reject_journal_values = 1'b1;
    engine.query_submission_journal(record.batch_key, snapshot, status);
    expect_status("JOURNAL_PROFILE_SEAM_DRIFT", status,
                  RDMA_SC_INVALID_STATE);
    if (snapshot != null)
      `uvm_error("JOURNAL_PROFILE_SEAM_DRIFT_OUTPUT",
                 "stored profile seam failure published a record")
    profile_a.reject_journal_values = 1'b0;

    engine.reset(reset_completions, status);
    expect_status("JOURNAL_RETAINED_RESET", status, RDMA_SC_OK);
    if (engine.state() != RDMA_CMQ_ENGINE_UNCONFIGURED ||
        engine.submission_journal_count() != 1 ||
        engine.journal_ticket_index_count() != 2 ||
        engine.preallocated_publish_batch_count() != 1 ||
        engine.journal_profile_count() != 1 ||
        !engine.journal_profile_matches(record.batch_key, profile_a))
      `uvm_error("JOURNAL_RETAINED_RESET_ROWS",
                 "reset deleted retained journal/profile authority")
    profile_a_calls = profile_a.journal_service_calls;
    engine.query_submission_journal_by_ticket(old_ticket, snapshot, status);
    expect_status("JOURNAL_OLD_TICKET_UNCONFIGURED", status, RDMA_SC_OK);
    expect_journal_snapshot(
      "JOURNAL_OLD_TICKET_UNCONFIGURED_GRAPH", engine, profile_a,
      snapshot, record
    );
    if (profile_a.journal_service_calls <= profile_a_calls)
      `uvm_error("JOURNAL_OLD_PROFILE_A_UNCONFIGURED",
                 "old query did not call retained profile A")

    profile_b = rdma_cmq_journal_tracking_profile::type_id::create(
      "submission_journal_profile_b"
    );
    profile_b.advertised_name = "rdma";
    profile_b.reject_journal_values = 1'b1;
    next_prepared = make_binding(
      "submission_journal_next_prepared", RDMA_BIND_PREPARED
    );
    next_active = make_binding(
      "submission_journal_next_active", RDMA_BIND_ACTIVE
    );
    next_prepared.generation++;
    status = next_prepared.synchronize_identity_from_legacy_mirrors();
    expect_status("JOURNAL_NEXT_PREPARED_ID", status, RDMA_SC_OK);
    next_prepared.owner_h = next_prepared.make_handle();
    next_active.generation++;
    status = next_active.synchronize_identity_from_legacy_mirrors();
    expect_status("JOURNAL_NEXT_ACTIVE_ID", status, RDMA_SC_OK);
    next_active.owner_h = next_active.make_handle();
    next_cmq = make_cmq("submission_journal_next_cmq", next_prepared);
    engine.prepare(
      next_prepared, next_cmq, 1'b1, 20'h34567, mem, scheduler, profile_b,
      runtime_desc, status
    );
    expect_status("JOURNAL_RETAINED_REPREPARE", status, RDMA_SC_OK);
    engine.activate(next_active, status);
    expect_status("JOURNAL_RETAINED_ACTIVATE", status, RDMA_SC_OK);
    profile_a_calls = profile_a.journal_service_calls;
    profile_b_calls = profile_b.journal_service_calls;
    engine.query_submission_journal(record.batch_key, snapshot, status);
    expect_status("JOURNAL_OLD_BATCH_ACTIVE", status, RDMA_SC_OK);
    expect_journal_snapshot(
      "JOURNAL_OLD_BATCH_ACTIVE_GRAPH", engine, profile_a, snapshot, record
    );
    engine.query_submission_journal_by_ticket(old_ticket, snapshot, status);
    expect_status("JOURNAL_OLD_TICKET_ACTIVE", status, RDMA_SC_OK);
    expect_journal_snapshot(
      "JOURNAL_OLD_TICKET_ACTIVE_GRAPH", engine, profile_a, snapshot, record
    );
    if (profile_a.journal_service_calls <= profile_a_calls ||
        profile_b.journal_service_calls != profile_b_calls)
      `uvm_error("JOURNAL_EXACT_PROFILE_SERVICE",
                 "old query used current profile B instead of retained A")

    if (!engine.tamper_submission_batch_digest(record.batch_key))
      `uvm_error("JOURNAL_DIGEST_TAMPER", "stored record was not present")
    engine.query_submission_journal(record.batch_key, snapshot, status);
    expect_status("JOURNAL_CORRUPT_DIGEST", status, RDMA_SC_INVALID_STATE);
    if (snapshot != null)
      `uvm_error("JOURNAL_CORRUPT_DIGEST_OUTPUT",
                 "corrupt digest query published a record")
    if (!engine.tamper_submission_batch_digest(record.batch_key))
      `uvm_error("JOURNAL_DIGEST_RESTORE", "stored digest restore failed")
    saved_body = record.items[0].command.body;
    unknown_body = new("submission_journal_stored_unknown_body");
    if (!engine.tamper_submission_command_body(
          record.batch_key, 0, unknown_body
        ))
      `uvm_error("JOURNAL_STORED_BODY_TAMPER",
                 "stored command body was not present")
    engine.query_submission_journal(record.batch_key, snapshot, status);
    expect_status("JOURNAL_STORED_UNKNOWN_BODY", status,
                  RDMA_SC_INVALID_STATE);
    if (snapshot != null)
      `uvm_error("JOURNAL_STORED_UNKNOWN_BODY_OUTPUT",
                 "stored unknown body query published a record")
    // reset/reprepare 已证明 public lifecycle 保留 journal；故障窗口结束前先恢复
    // 合法 body，再用 test probe 的真实删除入口关闭 fixture，不把 corruption 当修复语义。
    if (!engine.tamper_submission_command_body(
          record.batch_key, 0, saved_body
        ))
      `uvm_error("JOURNAL_STORED_BODY_RESTORE",
                 "stored command body restore failed")
    status = engine.remove_submission_journal_probe(record.batch_key);
    expect_status("JOURNAL_STORAGE_REMOVE", status, RDMA_SC_OK);
    if (engine.submission_journal_count() != 0 ||
        engine.journal_ticket_index_count() != 0 ||
        engine.preallocated_publish_batch_count() != 0 ||
        engine.journal_profile_count() != 0)
      `uvm_error("JOURNAL_STORAGE_REMOVE_COUNTS",
                 "storage cleanup left one or more retained rows")

    // reset/reprepare 后 engine counter 已属于新 incarnation；orphan allocation
    // 检查由 helper 在单一故障窗口内回拨并恢复，避免污染共享 fixture 的生命周期。
    check_journal_orphan_row_invariants(
      engine, profile_a, identity, record, preallocated
    );
    engine.shutdown(status);
    expect_status("JOURNAL_STORAGE_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：验证 pre-MMIO arm capability 仅能由登记的 exact observer 一次性消费，
  //   并在已持 engine_lock 时用预分配值原子安装 runtime publication 账本。
  // 输入/输出及副作用：无参数；自建 ACTIVE engine、PENDING_EFFECT journal、
  //   多个 forged observer 与 catcher；成功路径消费 observer/preallocation 行。
  // 失败/边界：伪造 identity、错 batch/attempt/incarnation、缺预分配、
  //   stale state、未登记、未配置/null-owner、null 参数与重复回调均必须单诊断且零状态变化。
  task automatic check_pre_mmio_arm_capability();
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_cmq_transport_scheduler_double scheduler;
    rdma_cmq_journal_tracking_profile profile_service;
    rdma_function_binding binding;
    rdma_function_identity identity;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_batch_submission_record record;
    rdma_cmq_batch_submission_record stored_record;
    rdma_cmq_batch_submission_record queried_record;
    rdma_cmq_preallocated_publish_batch preallocated;
    rdma_cmq_preallocated_publish_batch stored_preallocated;
    rdma_cmq_preallocated_publish_batch removed_preallocated;
    rdma_cmq_slot_record expected_slots[$];
    rdma_cmq_mmio_arm_observer authentic;
    rdma_cmq_mmio_arm_observer forged;
    rdma_cmq_mmio_arm_observer wrong_batch;
    rdma_cmq_mmio_arm_observer wrong_attempt;
    rdma_cmq_mmio_arm_observer wrong_incarnation;
    rdma_cmq_mmio_arm_observer unconfigured;
    rdma_cmq_mmio_arm_error_catcher catcher;
    rdma_status status;
    string batch_key;
    string capability_key;
    string before_state;
    string after_state;
    longint unsigned batch_id;
    longint unsigned attempt_id;
    int unsigned profile_calls_before;
    int unsigned errors_before;
    time callback_time;

    engine = rdma_cmq_engine_probe::type_id::create("mmio_arm_engine");
    mem = rdma_mock_host_mem::type_id::create("mmio_arm_mem");
    scheduler = rdma_cmq_transport_scheduler_double::type_id::create(
      "mmio_arm_scheduler"
    );
    profile_service = rdma_cmq_journal_tracking_profile::type_id::create(
      "mmio_arm_profile"
    );
    binding = make_binding("mmio_arm_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("mmio_arm_cmq", binding);
    engine.prepare(
      binding, cmq, 1'b1, 20'h34567, mem, scheduler, profile_service,
      runtime_desc, status
    );
    expect_status("MMIO_ARM_PREPARE", status, RDMA_SC_OK);
    status = binding.snapshot_identity_nonfatal(identity);
    expect_status("MMIO_ARM_IDENTITY", status, RDMA_SC_OK);
    status = engine.allocate_batch_identity_probe(identity, batch_key, batch_id);
    expect_status("MMIO_ARM_BATCH", status, RDMA_SC_OK);
    status = engine.allocate_attempt_identity_probe(attempt_id);
    expect_status("MMIO_ARM_ATTEMPT", status, RDMA_SC_OK);
    status = build_journal_fixture(
      "mmio_arm", engine, profile_service, binding, cmq, batch_key,
      batch_id, attempt_id, 64'h2000,
      RDMA_CMQ_TEST_JOURNAL_BODY_OBJECT_ID, record, preallocated
    );
    expect_status("MMIO_ARM_FIXTURE", status, RDMA_SC_OK);
    if (!make_pending_mmio_arm_fixture(record)) begin
      `uvm_error("MMIO_ARM_PENDING_FIXTURE",
                 "journal fixture could not enter PENDING_EFFECT")
      engine.shutdown(status);
      return;
    end
    engine.seed_ring_counters(record.start_sequence, record.start_sequence);
    status = engine.install_submission_journal_probe(record, preallocated);
    expect_status("MMIO_ARM_INSTALL", status, RDMA_SC_OK);
    stored_record = engine.journal_record_fault_reference(batch_key);
    stored_preallocated =
      engine.preallocated_publish_fault_reference(batch_key);
    if (stored_record == null || stored_preallocated == null ||
        stored_preallocated.items.size() != 2) begin
      `uvm_error("MMIO_ARM_STORED_FIXTURE",
                 "engine did not retain the complete arm fixture")
      engine.shutdown(status);
      return;
    end
    foreach (stored_preallocated.items[i])
      expected_slots.push_back(stored_preallocated.items[i].slot_record);

    capability_key = {batch_key, "|arm=0000000000000001"};
    authentic = new("mmio_arm_authentic");
    status = authentic.configure(
      engine, capability_key, batch_key, attempt_id,
      engine.journal_engine_incarnation()
    );
    expect_status("MMIO_ARM_CONFIGURE", status, RDMA_SC_OK);
    if (!authentic.is_configured() || authentic.owner_handle() != engine ||
        authentic.get_capability_key() != capability_key ||
        authentic.get_batch_key() != batch_key ||
        authentic.get_attempt_id() != attempt_id ||
        authentic.get_engine_incarnation() !=
          engine.journal_engine_incarnation())
      `uvm_error("MMIO_ARM_ACCESSORS",
                 "configured observer accessors changed immutable authority")
    status = authentic.configure(
      engine, {capability_key, "-again"}, batch_key, attempt_id + 1'b1,
      engine.journal_engine_incarnation() + 1'b1
    );
    expect_status("MMIO_ARM_CONFIGURE_ONESHOT", status, RDMA_SC_RESOURCE_BUSY);
    if (authentic.get_capability_key() != capability_key ||
        authentic.get_attempt_id() != attempt_id ||
        authentic.get_engine_incarnation() !=
          engine.journal_engine_incarnation())
      `uvm_error("MMIO_ARM_CONFIGURE_IMMUTABLE",
                 "second configure changed one-shot observer authority")
    if (!engine.register_mmio_arm_observer(capability_key, authentic))
      `uvm_error("MMIO_ARM_REGISTER", "authentic observer was not registered")

    catcher = new("mmio_arm_error_catcher");
    uvm_report_cb::add(null, catcher);

    forged = new("mmio_arm_forged");
    status = forged.configure(
      engine, capability_key, batch_key, attempt_id,
      engine.journal_engine_incarnation()
    );
    expect_status("MMIO_ARM_FORGED_CONFIGURE", status, RDMA_SC_OK);
    expect_mmio_arm_invalid_unchanged(
      "MMIO_ARM_FORGED", batch_key, engine, forged, catcher
    );

    if (!engine.unregister_mmio_arm_observer(capability_key))
      `uvm_error("MMIO_ARM_UNREGISTER", "authentic row could not be removed")
    expect_mmio_arm_invalid_unchanged(
      "MMIO_ARM_UNREGISTERED", batch_key, engine, authentic, catcher
    );
    if (!engine.register_mmio_arm_observer(capability_key, authentic))
      `uvm_error("MMIO_ARM_REREGISTER", "authentic row could not be restored")

    wrong_batch = new("mmio_arm_wrong_batch");
    status = wrong_batch.configure(
      engine, "wrong-batch-capability", "wrong-batch", attempt_id,
      engine.journal_engine_incarnation()
    );
    expect_status("MMIO_ARM_WRONG_BATCH_CONFIGURE", status, RDMA_SC_OK);
    if (!engine.register_mmio_arm_observer(
          wrong_batch.get_capability_key(), wrong_batch
        ))
      `uvm_error("MMIO_ARM_WRONG_BATCH_REGISTER",
                 "wrong-batch observer fixture was not registered")
    expect_mmio_arm_invalid_unchanged(
      "MMIO_ARM_WRONG_BATCH", batch_key, engine, wrong_batch, catcher
    );
    void'(engine.unregister_mmio_arm_observer(
      wrong_batch.get_capability_key()
    ));

    wrong_attempt = new("mmio_arm_wrong_attempt");
    status = wrong_attempt.configure(
      engine, "wrong-attempt-capability", batch_key, attempt_id + 1'b1,
      engine.journal_engine_incarnation()
    );
    expect_status("MMIO_ARM_WRONG_ATTEMPT_CONFIGURE", status, RDMA_SC_OK);
    if (!engine.register_mmio_arm_observer(
          wrong_attempt.get_capability_key(), wrong_attempt
        ))
      `uvm_error("MMIO_ARM_WRONG_ATTEMPT_REGISTER",
                 "wrong-attempt observer fixture was not registered")
    expect_mmio_arm_invalid_unchanged(
      "MMIO_ARM_WRONG_ATTEMPT", batch_key, engine, wrong_attempt, catcher
    );
    void'(engine.unregister_mmio_arm_observer(
      wrong_attempt.get_capability_key()
    ));

    wrong_incarnation = new("mmio_arm_wrong_incarnation");
    status = wrong_incarnation.configure(
      engine, "wrong-incarnation-capability", batch_key, attempt_id,
      engine.journal_engine_incarnation() + 1'b1
    );
    expect_status("MMIO_ARM_WRONG_INCARNATION_CONFIGURE", status, RDMA_SC_OK);
    if (!engine.register_mmio_arm_observer(
          wrong_incarnation.get_capability_key(), wrong_incarnation
        ))
      `uvm_error("MMIO_ARM_WRONG_INCARNATION_REGISTER",
                 "wrong-incarnation observer fixture was not registered")
    expect_mmio_arm_invalid_unchanged(
      "MMIO_ARM_WRONG_INCARNATION", batch_key, engine,
      wrong_incarnation, catcher
    );
    void'(engine.unregister_mmio_arm_observer(
      wrong_incarnation.get_capability_key()
    ));

    removed_preallocated = engine.take_preallocated_publish_batch(batch_key);
    if (removed_preallocated == null)
      `uvm_error("MMIO_ARM_DROP_PREALLOCATION",
                 "preallocation fixture could not be removed")
    expect_mmio_arm_invalid_unchanged(
      "MMIO_ARM_MISSING_PREALLOCATION", batch_key, engine,
      authentic, catcher
    );
    if (!engine.restore_preallocated_publish_batch(
          batch_key, removed_preallocated
        ))
      `uvm_error("MMIO_ARM_RESTORE_PREALLOCATION",
                 "preallocation fixture could not be restored")

    stored_record.state = RDMA_CMQ_SUBMISSION_STAGED;
    expect_mmio_arm_invalid_unchanged(
      "MMIO_ARM_STALE_STATE", batch_key, engine, authentic, catcher
    );
    stored_record.state = RDMA_CMQ_SUBMISSION_PENDING_EFFECT;

    unconfigured = new("mmio_arm_unconfigured");
    status = unconfigured.configure(
      null, "unconfigured-capability", batch_key, attempt_id,
      engine.journal_engine_incarnation()
    );
    expect_status("MMIO_ARM_NULL_OWNER_CONFIGURE", status,
                  RDMA_SC_INVALID_ARGUMENT);
    if (unconfigured.is_configured() || unconfigured.owner_handle() != null)
      `uvm_error("MMIO_ARM_NULL_OWNER_STATE",
                 "failed configure published a partial owner capability")
    expect_mmio_arm_invalid_unchanged(
      "MMIO_ARM_UNCONFIGURED", batch_key, engine, unconfigured, catcher
    );

    before_state = engine.mmio_arm_state_fingerprint(batch_key);
    errors_before = catcher.caught_count;
    engine.arm_submission_for_mmio(null);
    after_state = engine.mmio_arm_state_fingerprint(batch_key);
    if (catcher.caught_count != errors_before + 1 ||
        after_state != before_state)
      `uvm_error("MMIO_ARM_NULL_OBSERVER",
                 "null observer diagnostic changed engine state")

    profile_calls_before = profile_service.journal_service_calls;
    callback_time = $time;
    engine.call_mmio_arm_while_engine_lock_held(authentic);
    if ($time != callback_time || scheduler.submit_calls != 0 ||
        profile_service.journal_service_calls != profile_calls_before)
      `uvm_error("MMIO_ARM_REENTRY",
                 "valid callback waited or re-entered scheduler/profile")
    if (engine.mmio_arm_publish_sequence() != stored_record.end_sequence ||
        engine.preallocated_publish_batch_count() != 0 ||
        engine.mmio_arm_observer_count() != 0 ||
        stored_record.state != RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS ||
        stored_record.submission_effect !=
          RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE ||
        stored_record.attempt_effect !=
          RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE ||
        !stored_record.observer_armed)
      `uvm_error("MMIO_ARM_COMMIT",
                 "valid callback did not atomically commit batch evidence")
    foreach (stored_record.items[i]) begin
      if (stored_record.items[i].state !=
            RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS ||
          stored_record.items[i].submission_effect !=
            RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE ||
          stored_record.items[i].attempt_effect !=
            RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE ||
          stored_record.items[i].completion_phase !=
            RDMA_CMQ_COMPLETION_PENDING ||
          !stored_record.items[i].recovery_required ||
          engine.mmio_arm_slot_reference(
            stored_record.items[i].slot_index
          ) != expected_slots[i] ||
          !engine.mmio_arm_token_in_use(
            stored_record.items[i].command_token
          ) ||
          engine.mmio_arm_command_reference(
            stored_preallocated.items[i].command_key
          ) != expected_slots[i] ||
          engine.mmio_arm_entry_reference(
            stored_preallocated.items[i].entry_key
          ) != expected_slots[i])
        `uvm_error("MMIO_ARM_ITEM_COMMIT",
                   $sformatf("item %0d did not transfer exact preallocation", i))
    end

    expect_mmio_arm_invalid_unchanged(
      "MMIO_ARM_DUPLICATE", batch_key, engine, authentic, catcher
    );
    if (catcher.caught_count != 10)
      `uvm_error("MMIO_ARM_ERROR_COUNT",
                 $sformatf("caught %0d stable errors instead of 10",
                           catcher.caught_count))
    uvm_report_cb::delete(null, catcher);

    engine.query_submission_journal(batch_key, queried_record, status);
    expect_status("MMIO_ARM_QUERY_AFTER_COMMIT", status, RDMA_SC_OK);
    if (queried_record == null || queried_record.observer_armed != 1'b1 ||
        queried_record.state != RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS)
      `uvm_error("MMIO_ARM_QUERY_AFTER_COMMIT_OUTPUT",
                 "consumed preallocation made armed journal unqueryable")
    status = engine.remove_submission_journal_probe(batch_key);
    expect_status("MMIO_ARM_REMOVE_AFTER_COMMIT", status, RDMA_SC_OK);
    engine.shutdown(status);
    expect_status("MMIO_ARM_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：在 persistent hostile raw-factory override 下验证所有 Task 13 snapshot
  //   seam 只用 direct-new/profile typed copy，并非致命拒绝未知 body/payload。
  // 输入/输出及副作用：无参数；先构造完整 source graph，再永久安装 overrides，
  //   用 callback 捕获 fatal 计数，并逐项安装、查询、删除五个 row；必须是最后场景。
  // 失败/边界：任一 trap 构造/FCTTYP/fatal、partial output、alias topology 漂移或
  //   unknown polymorph 非 INVALID_ARGUMENT/null 都报告 UVM_ERROR。
  task automatic check_journal_hostile_factory_snapshots_last();
    rdma_cmq_test_journal_body_e body_kinds[5];
    rdma_cmq_engine_probe engine;
    rdma_mock_host_mem mem;
    rdma_doorbell_scheduler scheduler;
    rdma_hw_cmq_hw_profile profile;
    rdma_function_binding binding;
    rdma_function_identity identity;
    rdma_cmq cmq;
    rdma_cmq_runtime_desc runtime_desc;
    rdma_cmq_batch_submission_record record;
    rdma_cmq_batch_submission_record snapshot;
    rdma_cmq_batch_submission_record records[5];
    rdma_cmq_preallocated_publish_batch preallocated_batches[5];
    rdma_cmq_execution_result result;
    rdma_cmq_execution_result result_snapshot;
    rdma_cmq_submission_recovery_request request;
    rdma_cmq_submission_recovery_request request_snapshot;
    rdma_cmq_reset_isolation_proof proof;
    rdma_cmq_reset_isolation_proof proof_snapshot;
    rdma_cmq_command_desc unknown_command;
    rdma_cmq_command_desc command_snapshot;
    rdma_cmq_unknown_body unknown_body;
    rdma_cmq_unknown_completion_payload unknown_payload;
    uvm_object saved_payload;
    rdma_cmq_journal_fatal_catcher catcher;
    rdma_status status;
    string batch_key;
    longint unsigned batch_id;
    longint unsigned attempt_id;

    body_kinds[0] = RDMA_CMQ_TEST_JOURNAL_BODY_QPC;
    body_kinds[1] = RDMA_CMQ_TEST_JOURNAL_BODY_OBJECT_ID;
    body_kinds[2] = RDMA_CMQ_TEST_JOURNAL_BODY_MR_DEREGISTER;
    body_kinds[3] = RDMA_CMQ_TEST_JOURNAL_BODY_OCC_FLUSH;
    body_kinds[4] = RDMA_CMQ_TEST_JOURNAL_BODY_EMPTY;

    engine = rdma_cmq_engine_probe::type_id::create(
      "journal_hostile_engine"
    );
    mem = rdma_mock_host_mem::type_id::create("journal_hostile_mem");
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "journal_hostile_scheduler"
    );
    profile = rdma_hw_cmq_hw_profile::type_id::create(
      "journal_hostile_profile"
    );
    binding = make_binding("journal_hostile_binding", RDMA_BIND_PREPARED);
    cmq = make_cmq("journal_hostile_cmq", binding);
    engine.prepare(
      binding, cmq, 1'b1, 20'h34567, mem, scheduler, profile,
      runtime_desc, status
    );
    expect_status("JOURNAL_HOSTILE_PREPARE", status, RDMA_SC_OK);
    status = binding.snapshot_identity_nonfatal(identity);
    expect_status("JOURNAL_HOSTILE_IDENTITY", status, RDMA_SC_OK);
    foreach (body_kinds[i]) begin
      status = engine.allocate_batch_identity_probe(
        identity, batch_key, batch_id
      );
      expect_status(
        $sformatf("JOURNAL_HOSTILE_BATCH_%0d", i), status, RDMA_SC_OK
      );
      status = engine.allocate_attempt_identity_probe(attempt_id);
      expect_status(
        $sformatf("JOURNAL_HOSTILE_ATTEMPT_%0d", i), status, RDMA_SC_OK
      );
      status = build_journal_fixture(
        $sformatf("journal_hostile_%0d", i), engine, profile, binding,
        cmq, batch_key, batch_id, attempt_id,
        64'h7000 + longint'(i) * 64'h0100, body_kinds[i], records[i],
        preallocated_batches[i]
      );
      expect_status(
        $sformatf("JOURNAL_HOSTILE_FIXTURE_%0d", i), status, RDMA_SC_OK
      );
      if (records[i] == null || preallocated_batches[i] == null)
        `uvm_error($sformatf("JOURNAL_HOSTILE_FIXTURE_OUTPUT_%0d", i),
                   "hostile body source graph construction was incomplete")
    end
    record = records[1];
    status = build_journal_recovery_graphs(
      "journal_hostile", record, result, request, proof
    );
    expect_status("JOURNAL_HOSTILE_RECOVERY_FIXTURE", status, RDMA_SC_OK);
    if (record == null || preallocated_batches[1] == null ||
        result == null || request == null || proof == null) begin
      `uvm_error("JOURNAL_HOSTILE_FIXTURE_OUTPUT",
                 "hostile source graph construction was incomplete")
      engine.shutdown(status);
      return;
    end

    configure_journal_factory_traps();
    rdma_cmq_journal_factory_counter::clear();
    catcher = new("journal_hostile_fatal_catcher");
    uvm_report_cb::add(null, catcher);

    foreach (records[i]) begin
      status = engine.install_submission_journal_probe(
        records[i], preallocated_batches[i]
      );
      expect_status(
        $sformatf("JOURNAL_HOSTILE_INSTALL_%0d", i), status, RDMA_SC_OK
      );
      engine.query_submission_journal(
        records[i].batch_key, snapshot, status
      );
      expect_status(
        $sformatf("JOURNAL_HOSTILE_QUERY_BATCH_%0d", i), status,
        RDMA_SC_OK
      );
      expect_journal_snapshot(
        $sformatf("JOURNAL_HOSTILE_QUERY_BATCH_GRAPH_%0d", i), engine,
        profile, snapshot, records[i]
      );
      if (i == 1) begin
        engine.query_submission_journal_by_ticket(
          record.items[1].ticket, snapshot, status
        );
        expect_status("JOURNAL_HOSTILE_QUERY_TICKET", status, RDMA_SC_OK);
        expect_journal_snapshot(
          "JOURNAL_HOSTILE_QUERY_TICKET_GRAPH", engine, profile,
          snapshot, record
        );
      end
      status = engine.remove_submission_journal_probe(records[i].batch_key);
      expect_status(
        $sformatf("JOURNAL_HOSTILE_REMOVE_%0d", i), status, RDMA_SC_OK
      );
      records[i] = null;
      preallocated_batches[i] = null;
      snapshot = null;
    end
    if (engine.submission_journal_count() != 0 ||
        engine.journal_ticket_index_count() != 0 ||
        engine.preallocated_publish_batch_count() != 0 ||
        engine.journal_profile_count() != 0)
      `uvm_error("JOURNAL_HOSTILE_REMOVE_COUNTS",
                 "hostile cleanup left one or more retained rows")

    status = engine.snapshot_execution_result_probe(
      result, result_snapshot
    );
    expect_status("JOURNAL_HOSTILE_RESULT", status, RDMA_SC_OK);
    if (result_snapshot == null || result_snapshot == result ||
        result_snapshot.ticket == null ||
        result_snapshot.completion == null ||
        result_snapshot.status == null ||
        result_snapshot.recovery_owner == null ||
        result_snapshot.dma_context == null ||
        result_snapshot.command_identity == null ||
        result_snapshot.ticket != result_snapshot.completion.ticket ||
        result_snapshot.status != result_snapshot.completion.status ||
        result_snapshot.ticket == result.ticket ||
        result_snapshot.recovery_owner == result.recovery_owner)
      `uvm_error("JOURNAL_HOSTILE_RESULT_GRAPH",
                 "execution-result snapshot is partial or aliased")

    status = engine.snapshot_recovery_request_probe(
      request, request_snapshot
    );
    expect_status("JOURNAL_HOSTILE_REQUEST", status, RDMA_SC_OK);
    if (request_snapshot == null || request_snapshot == request ||
        request_snapshot.items.size() != request.items.size() ||
        request_snapshot.reset_isolation_proof == null ||
        request_snapshot.reset_isolation_proof == proof ||
        request_snapshot.items[0] == null ||
        request_snapshot.items[1] == null ||
        request_snapshot.items[0].recovery_owner == null ||
        request_snapshot.items[0].recovery_owner !=
          request_snapshot.items[1].recovery_owner ||
        request_snapshot.items[0].command == null ||
        request_snapshot.items[0].command.recovery_owner !=
          request_snapshot.items[0].recovery_owner ||
        request_snapshot.items[0].ticket == request.items[0].ticket)
      `uvm_error("JOURNAL_HOSTILE_REQUEST_GRAPH",
                 "recovery-request snapshot is partial or lost aliases")

    status = engine.snapshot_reset_proof_probe(proof, proof_snapshot);
    expect_status("JOURNAL_HOSTILE_PROOF", status, RDMA_SC_OK);
    if (proof_snapshot == null || proof_snapshot == proof ||
        proof_snapshot.isolated_identity == null ||
        proof_snapshot.isolated_identity == proof.isolated_identity ||
        proof_snapshot.isolated_recovery_owners.size() != 2 ||
        proof_snapshot.isolated_recovery_owners[0] == null ||
        proof_snapshot.isolated_recovery_owners[0] !=
          proof_snapshot.isolated_recovery_owners[1] ||
        proof_snapshot.isolated_recovery_owners[0] ==
          proof.isolated_recovery_owners[0] ||
        proof_snapshot.proof_digest != proof.proof_digest)
      `uvm_error("JOURNAL_HOSTILE_PROOF_GRAPH",
                 "reset-proof snapshot is partial, aliased or unequal")

    unknown_command = new("journal_hostile_unknown_command");
    unknown_command.function_h = record.items[0].command.function_h;
    unknown_command.opcode_key = record.items[0].command.opcode_key;
    unknown_body = new("journal_hostile_unknown_body");
    unknown_command.body = unknown_body;
    unknown_command.qpc_signature_source =
      record.items[0].command.qpc_signature_source;
    unknown_command.vfid_override = record.items[0].command.vfid_override;
    unknown_command.use_vfid = record.items[0].command.use_vfid;
    unknown_command.timeout = record.items[0].command.timeout;
    unknown_command.recovery_owner = record.items[0].recovery_owner;
    status = engine.snapshot_command_for_journal_probe(
      unknown_command, unknown_command.recovery_owner, command_snapshot
    );
    expect_status("JOURNAL_HOSTILE_UNKNOWN_BODY", status,
                  RDMA_SC_INVALID_ARGUMENT);
    if (command_snapshot != null)
      `uvm_error("JOURNAL_HOSTILE_UNKNOWN_BODY_OUTPUT",
                 "unknown command body published a partial snapshot")

    saved_payload = result.completion.decoded_response;
    unknown_payload = new("journal_hostile_unknown_payload");
    unknown_payload.marker = 32'hfeed_beef;
    result.completion.decoded_response = unknown_payload;
    status = engine.snapshot_execution_result_probe(
      result, result_snapshot
    );
    result.completion.decoded_response = saved_payload;
    expect_status("JOURNAL_HOSTILE_UNKNOWN_PAYLOAD", status,
                  RDMA_SC_INVALID_ARGUMENT);
    if (result_snapshot != null)
      `uvm_error("JOURNAL_HOSTILE_UNKNOWN_PAYLOAD_OUTPUT",
                 "unknown completion payload published a partial result")

    uvm_report_cb::delete(null, catcher);
    if (rdma_cmq_journal_factory_counter::call_count() != 0 ||
        catcher.caught_count != 0 || catcher.factory_type_count != 0)
      `uvm_error("JOURNAL_HOSTILE_FACTORY",
                 $sformatf("raw factory/fatal/FCTTYP counts are %0d/%0d/%0d",
                           rdma_cmq_journal_factory_counter::call_count(),
                           catcher.caught_count,
                           catcher.factory_type_count))

    engine.shutdown(status);
    expect_status("JOURNAL_HOSTILE_SHUTDOWN", status, RDMA_SC_OK);
  endtask

  // 功能：驱动 rdma_cmq_engine 全部回归，并在 storage 与永久 hostile factory
  //   override 之间建立一个无 live transaction 的 fixture 回收时间槽。
  // 输入/输出及副作用：phase 由 UVM 输入；task 管理 objection、执行断言，并在
  //   storage shutdown 后推进 1ns，再运行必须位于末尾的 hostile 场景。
  // 失败/边界：任一场景以 UVM severity 暴露失败；1ns 边界只允许出现在四表已空、
  //   engine 已 shutdown 后，末尾无论断言结果都必须释放 objection。
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_transport_facade_contract();
    check_transport_engine_lifecycle();
    check_success_and_detachment();
    check_preallocation_rejections();
    check_pasid_normalization_and_busy_prepare();
    check_allocation_and_rollback_failures();
    check_null_status_guards();
    check_prepared_shutdown_lifecycle();
    check_shutdown_release_retry();
    check_active_shutdown_release_retry();
    check_null_shutdown_release_retry();
    check_missing_host_mem_shutdown();
    check_activation_guards();
    check_batch_compaction_and_doorbell();
    // Keep the 32-entry capacity stress near the ring/batch guards and before
    // poll hook regressions to limit VCS peak retained-object pressure.
    check_full_initial_capacity_and_shutdown_reset();
    check_empty_invalid_and_state_rejections();
    check_poll_empty_ledger_and_partial_drain();
    check_pre_read_poll_ledger_fail_closed();
    check_submit_wrapper_and_snapshot_detachment();
    check_null_compose_transaction_abort();
    check_nested_command_snapshot_failures();
    check_mutating_clone_source_restoration();
    check_qpc_context_snapshot_failures();
    check_transaction_failure_atomicity();
    check_profile_wide_cqe_format_authority();
    check_all_transport_failure_rollbacks();
    check_doorbell_authority_isolation();
    check_submission_validation_and_profile_metadata();
    check_profile_hook_snapshot_contract();
    check_stateful_profile_snapshot_rechecks();
    check_exact_type_profile_delegation();
    check_internal_invariant_batch_abort();
    check_timeout_quarantine_and_late_diagnostic();
    check_expire_snapshot_failure_is_atomic_and_retryable();
    check_late_diagnostic_snapshot_failure_is_retryable();
    check_command_incarnation_exhaustion();
    check_incarnation_survives_reprepare();
    check_max_dependency_id_boundary();
    check_counter_invariants_poison_before_transport();
    check_poll_raw_snapshot_rejects_self_clone_mutation();
    check_poll_payload_retained_self_clone_is_detached();
    check_poll_payload_hook_contract_failures();
    check_poll_decoded_status_contract_failures();
    check_poll_ticket_root_is_explicitly_constructed();
    check_retirement_preflight_poison_atomicity();
    check_cqe_poison_isolation_and_snapshot_detachment();
    check_poison_shutdown_release_retry_preserves_snapshot();
    check_wait_rejects_x_deadline_without_side_effects();
    check_wait_poison_lifecycle_boundaries();
    check_wait_for_caller_ticket_detachment();
    check_wait_for_fifo_and_deadline();
    check_cancel_reset_and_shutdown_lifecycle();
    check_strict_cancel_audits_complete_ledger();
    check_strict_cancel_audits_exact_membership();
    check_poison_recovery_rejects_x_tickets();
    check_poisoned_ledger_reset_recovery();
    check_reset_fifo_retry_and_reprepare();
    check_poll_backing_out_of_order_and_owner_wrap();
    check_retire_then_wrap_publication();
    check_journal_identity_and_counter_contract();
    check_submission_journal_storage_and_queries();
    check_pre_mmio_arm_capability();
    // storage engine 已 shutdown 且四张 retained 表为空；推进一个 test-only tick，
    // 让模拟器在安装永久 factory override 前回收上一 automatic fixture 的复杂 graph。
    // 此边界没有 live DUT transaction，不改变任何被测 lifecycle 或超时语义。
    #1ns;
    // Raw UVM factory overrides persist globally, so this must remain last.
    check_journal_hostile_factory_snapshots_last();
    phase.drop_objection(this);
  endtask
endclass
