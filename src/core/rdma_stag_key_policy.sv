// 目录：核心执行层 core/rdma_stag_key_policy.sv。
// 职责：实现 rdma_stag_key_policy 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_stag_key_policy.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_stag_key_policy extends uvm_object;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_stag_key_policy");
    super.new(name);
  endfunction

  // 功能：处理 derive：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 mr, stag_key 用于执行 derive；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：derive 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  pure virtual function rdma_status derive(
    rdma_mr mr,
    output bit [7:0] stag_key
  );
endclass

class rdma_incarnation_stag_key_policy extends rdma_stag_key_policy;
  `uvm_object_utils(rdma_incarnation_stag_key_policy)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_incarnation_stag_key_policy");
    super.new(name);
  endfunction

  // 功能：处理 derive：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 mr, stag_key 用于执行 derive；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：derive 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  virtual function rdma_status derive(
    rdma_mr mr,
    output bit [7:0] stag_key
  );
    stag_key = '0;
    if (mr == null || mr.handle == null ||
        mr.handle.kind != RDMA_RESOURCE_MR)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MR STAG key source is invalid");
    stag_key = mr.handle.object_id[7:0];
    return rdma_status::success();
  endfunction
endclass
