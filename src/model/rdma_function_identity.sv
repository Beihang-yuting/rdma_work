// 目录：协议与资源模型层 model/rdma_function_identity.sv。
// 职责：定义 Function 身份值对象及其比较/校验接口。
// 依赖：依赖本层公共 types 与 route/key 辅助函数。
// 所有权与生命周期：对象只拥有值快照；随拥有者结束，不持有外部资源。

// 中文说明：跨 Host/root 隔离的 Function 身份值快照与唯一权威。创建者通过 configure()
// 写入；binding 持有其克隆作为 authority，调用方读取 detached snapshot。
class rdma_function_identity extends uvm_object;
  `uvm_object_utils(rdma_function_identity)

  rdma_function_key_t key;
  int unsigned global_function_id;
  longint unsigned function_uid;
  int unsigned generation;
  rdma_reset_epoch_t reset_epoch;

  // 功能：构造 identity，所有字段清零。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无；未 configure 前 validate() 会拒绝。
  function new(string name = "rdma_function_identity");
    super.new(name);
    key = '0;
    global_function_id = 0;
    function_uid = 0;
    generation = 0;
    reset_epoch = 0;
  endfunction

  // 功能：写入 Function key、全局 ID、UID、generation 与 reset epoch，并调用 validate()。
  // 输入/输出及副作用：覆盖全部字段；返回 validate() 的 status。
  // 失败/边界：校验失败时字段已被覆盖，不回滚，调用方须丢弃该 identity。
  function rdma_status configure(
    rdma_function_key_t new_key,
    int unsigned new_global_id,
    longint unsigned new_uid,
    int unsigned new_generation,
    longint unsigned new_reset_epoch
  );
    key = new_key;
    global_function_id = new_global_id;
    function_uid = new_uid;
    generation = new_generation;
    reset_epoch = new_reset_epoch;
    return validate();
  endfunction

  // 功能：由 key 投影出 route key。
  // 输入/输出及副作用：无参数；返回值快照，不修改 identity。
  // 失败/边界：不校验；key 无效时的投影不得被 router 接受，须先 validate()。
  function rdma_route_key_t route_key();
    // 只是值投影；调用方须先通过 validate()。
    return rdma_route_key_from_function(key);
  endfunction

  // 功能：比较两个 identity 是否属于同一 Function（key 与 global_function_id）。
  // 输入/输出及副作用：rhs 只读；返回 bit，无副作用。
  // 失败/边界：rhs 为空返回 0。
  function bit same_function(rdma_function_identity rhs);
    if (rhs == null) return 1'b0;
    // 逐成员比较：部分仿真器不接受类方法中的 packed struct 相等，且保持 Host/root/BDF 均参与身份。
    return key.root_id == rhs.key.root_id &&
           key.host_topology_key == rhs.key.host_topology_key &&
           key.function_kind == rhs.key.function_kind &&
           key.parent_pf_bdf.segment == rhs.key.parent_pf_bdf.segment &&
           key.parent_pf_bdf.bus == rhs.key.parent_pf_bdf.bus &&
           key.parent_pf_bdf.device == rhs.key.parent_pf_bdf.device &&
           key.parent_pf_bdf.function_num == rhs.key.parent_pf_bdf.function_num &&
           key.vf_index == rhs.key.vf_index &&
           key.bdf.segment == rhs.key.bdf.segment &&
           key.bdf.bus == rhs.key.bdf.bus &&
           key.bdf.device == rhs.key.bdf.device &&
           key.bdf.function_num == rhs.key.bdf.function_num &&
           global_function_id == rhs.global_function_id;
  endfunction

  // 功能：比较是否同一 incarnation（同一 Function 且 UID、generation、reset_epoch 一致）。
  // 输入/输出及副作用：rhs 只读；返回 bit，无副作用。
  // 失败/边界：rhs 为空或 Function 不同返回 0。
  function bit same_incarnation(rdma_function_identity rhs);
    if (!same_function(rhs)) return 1'b0;
    return function_uid == rhs.function_uid &&
           generation == rhs.generation && reset_epoch == rhs.reset_epoch;
  endfunction

  // 功能：校验 UID、generation 非零及 Function route/parent/BDF 合法。
  // 输入/输出及副作用：只读字段；返回新建 status。
  // 失败/边界：UID 为 0、generation 为 0 或 route/BDF 非法时返回 INVALID_ARGUMENT。
  function rdma_status validate();
    if (function_uid == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function UID must be non-zero");
    if (generation == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function generation must be non-zero");
    if (!rdma_function_key_route_valid(key))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function route/parent/BDF identity is invalid");
    return rdma_status::success();
  endfunction

  // 功能：把 rhs 的值字段复制到当前对象。
  // 输入/输出及副作用：rhs 为源对象，不被修改；覆盖当前对象全部字段。
  // 失败/边界：rhs 类型不匹配时触发 UVM fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_function_identity source;
    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "Function identity copy type mismatch")
    key = source.key;
    global_function_id = source.global_function_id;
    function_uid = source.function_uid;
    generation = source.generation;
    reset_epoch = source.reset_epoch;
  endfunction
endclass
