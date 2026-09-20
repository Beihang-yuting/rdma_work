// 目录：测试层 unit/rdma_cmq_journal_factory_fixture.sv。
// 职责：提供 CMQ journal hostile-factory 场景使用的计数器和派生 trap fixture，
//   将禁止的 raw UVM factory 构造转化为可断言的本地证据。
// 依赖：依赖 rdma_model_pkg 中的 CMQ journal、recovery、completion、body 类型，
//   以及当前 compilation unit 已导入的 UVM macros；不依赖 engine test class。
// 所有权与生命周期：fixture 只拥有静态计数值和每次 trap 构造的本地 UVM 对象；
//   factory override 由 scenario 安装，进程退出负责隔离 override 生命周期。

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
