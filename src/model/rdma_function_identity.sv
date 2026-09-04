// 目录：协议与资源模型层 model/rdma_function_identity.sv。
// 职责：实现 rdma_function_identity 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：本类是跨 Host/root 隔离的 Function 身份值快照与唯一权威。
// 创建者通过 configure() 写入；binding 持有其克隆作为 authority，调用方
// 读取 detached snapshot。对象生命周期随拥有者结束，不单独释放外部资源。
class rdma_function_identity extends uvm_object;
  `uvm_object_utils(rdma_function_identity)

  rdma_function_key_t key;
  int unsigned global_function_id;
  longint unsigned function_uid;
  int unsigned generation;
  rdma_reset_epoch_t reset_epoch;

  // 功能：构造 rdma_function_identity，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：key='0；global_function_id=0；function_uid=0；generation=0；reset_epoch=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_function_identity 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_function_identity");
    super.new(name);
    key = '0;
    global_function_id = 0;
    function_uid = 0;
    generation = 0;
    reset_epoch = 0;
  endfunction

  // 功能：在 rdma_function_identity 中，configure 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：new_key（输入）、new_global_id（输入）、new_uid（输入）、new_generation（输入）、new_reset_epoch（输入）；configure 先依据 依赖存在性、authority 和 generation 条件 校验 new_key、new_global_id、new_uid、new_generation、new_reset_epoch；成功时更新本对象配置/状态并保存非拥有引用，返回
  //   rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
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

  // 功能：在 rdma_function_identity 中，route_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：无显式参数；返回 detached route key，不修改 identity 或外部路由表。
  // 失败/边界：目标不存在、route/authority 不匹配或快照代际失效时返回错误/空值；不得返回陈旧或歧义条目。
  function rdma_route_key_t route_key();
    // 中文：route_key 只是值投影；调用方必须先通过 validate()，无效 key
    // 投影出来的 route 不得被 router 接受。
    return rdma_route_key_from_function(key);
  endfunction

  // 功能：在 rdma_function_identity 中由 same_function 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：rhs（输入）；lhs/rhs 只读，返回 bit，不更新 authority 或资源账本。
  // 失败/边界：same_function 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  function bit same_function(rdma_function_identity rhs);
    if (rhs == null) return 1'b0;
    // Compare packed key members explicitly; some simulators reject packed
    // struct equality in class methods and this keeps the route semantics
    // visible (Host/root/BDF are all part of function identity).
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

  // 功能：在 rdma_function_identity 中由 same_incarnation 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：rhs（输入）；两份 identity 只读，返回 bit，不修改 reset ledger。
  // 失败/边界：same_incarnation 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  function bit same_incarnation(rdma_function_identity rhs);
    if (!same_function(rhs)) return 1'b0;
    return function_uid == rhs.function_uid &&
           generation == rhs.generation && reset_epoch == rhs.reset_epoch;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“Function UID must be non-zero”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、function_uid、generation、key 并使用字段 rdma_status、function_uid、generation、key；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“Function UID must be non-zero”“Function generation must be non-zero”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：将 rhs 中 rdma_function_identity 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（Function identity copy type mismatch），不保留部分有效快照。
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
