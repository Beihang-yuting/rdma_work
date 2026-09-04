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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_function_identity");
    super.new(name);
    key = '0;
    global_function_id = 0;
    function_uid = 0;
    generation = 0;
    reset_epoch = 0;
  endfunction

  // 功能：校验依赖并建立该对象的运行边界，成功后保存必要的非拥有引用；拒绝不完整或重复配置。
  // 输入/输出及副作用：接收 manager、binding、router 或 profile 等依赖；成功后保存非拥有引用并更新配置状态。
  //   任一依赖为空、重复配置或代际不匹配时保持原状态并返回错误。
  // 失败/边界：配置失败不得写入半成品引用；已激活对象不得被无条件降级或重复占用资源。
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

  // 功能：处理 route_key：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 无显式输入参数 用于执行 route_key；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：route_key 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function rdma_route_key_t route_key();
    // 中文：route_key 只是值投影；调用方必须先通过 validate()，无效 key
    // 投影出来的 route 不得被 router 接受。
    return rdma_route_key_from_function(key);
  endfunction

  // 功能：比较两个输入对象的协议字段或身份快照并返回确定的相等性结果，不修改任一输入。
  // 输入/输出及副作用：输入为待比较的两个值对象；返回 bit/状态结果，不修改任一输入或外部账本。
  //   任一对象为空、类型不符或字段未初始化时按接口约定返回不相等或错误。
  // 失败/边界：比较输入为空或类型不符时不得抛出未处理异常；结果必须保持确定且无副作用。
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

  // 功能：比较两个输入对象的协议字段或身份快照并返回确定的相等性结果，不修改任一输入。
  // 输入/输出及副作用：输入为待比较的两个值对象；返回 bit/状态结果，不修改任一输入或外部账本。
  //   任一对象为空、类型不符或字段未初始化时按接口约定返回不相等或错误。
  // 失败/边界：比较输入为空或类型不符时不得抛出未处理异常；结果必须保持确定且无副作用。
  function bit same_incarnation(rdma_function_identity rhs);
    if (!same_function(rhs)) return 1'b0;
    return function_uid == rhs.function_uid &&
           generation == rhs.generation && reset_epoch == rhs.reset_epoch;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
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

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
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
