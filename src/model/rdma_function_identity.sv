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

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_function_identity");
    super.new(name);
    key = '0;
    global_function_id = 0;
    function_uid = 0;
    generation = 0;
    reset_epoch = 0;
  endfunction

  // 功能：写入并校验运行所需的配置、身份或资源参数，建立后续操作的边界（接口 configure）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：执行接口 route_key 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 route_key）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function rdma_route_key_t route_key();
    // 中文：route_key 只是值投影；调用方必须先通过 validate()，无效 key
    // 投影出来的 route 不得被 router 接受。
    return rdma_route_key_from_function(key);
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 same_function）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 same_incarnation）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function bit same_incarnation(rdma_function_identity rhs);
    if (!same_function(rhs)) return 1'b0;
    return function_uid == rhs.function_uid &&
           generation == rhs.generation && reset_epoch == rhs.reset_epoch;
  endfunction

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 validate）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 do_copy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
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
