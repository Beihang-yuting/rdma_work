// 目录：核心执行层 core/rdma_cmq_port.sv。
// 职责：实现 rdma_cmq_port 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_cmq_port.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_cmq_port extends uvm_object;

  // 功能：构造 rdma_cmq_port，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_port 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_port");
    super.new(name);
  endfunction

  // 功能：在 rdma_cmq_port 中，execute 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：command（输入）、ticket（输出）、completion（输出）、status（输出）；execute 驱动下游事务，并写入 ticket、completion、status；函数返回 无直接返回值，不取得调用方资源所有权。

  // 失败/边界：execute 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  pure virtual task execute(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );

  // 功能：在 rdma_cmq_port 中，reconcile 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：ticket（输入）、terminal_known（输出）、completion（输出）、status（输出）；输入 action/epoch/handle
  //   决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：reconcile 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  pure virtual task reconcile(
    rdma_cmq_ticket ticket,
    output bit terminal_known,
    output rdma_cmq_completion completion,
    output rdma_status status
  );

  // A missing ticket/completion is not proof that a command was rejected
  // before submission.  An adapter may override this observation when it can
  // prove that the most recent execute() failed in its own pre-submit
  // validation path.  The conservative default is fail-closed.
  // 功能：在 rdma_cmq_port 中，last_execute_definitive_no_submit 只读查询当前运行时/测试账本，返回槽位、对象或恢复记录的快照而不推进事务。
  // 输入/输出及副作用：无显式参数；last_execute_definitive_no_submit 读取 last_execute 的 submitted、completed 和 definitive_no_submit 标志，返回是否明确未提交；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：last_execute_definitive_no_submit 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  virtual function bit last_execute_definitive_no_submit();
    return 1'b0;
  endfunction
endclass
