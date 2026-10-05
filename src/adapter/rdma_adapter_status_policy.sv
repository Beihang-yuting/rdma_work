// 目录/层次：适配器接口层 adapter/rdma_adapter_status_policy.sv。
// 职责：集中定义外部 adapter 返回 null status 时的 fail-closed 归一化规则，供 Host-memory API 与具体 adapter 共用。
// 依赖：rdma_types_pkg 的 rdma_status；不访问 Host-memory、PCIe、network、manager、router 或可变账本。
// 所有权与生命周期：只创建 detached rdma_status 值；不保存调用方引用，不取得外部资源所有权。

// 设计说明：adapter 契约要求所有 backend 调用返回非空 rdma_status；null 是下游契约违例，不能当成功或继续读 output。
//  错误构造独立成纯值 policy，避免基类与具体 adapter 维护两套诊断前缀。
class rdma_adapter_status_policy extends uvm_object;
  `rdma_object_utils(rdma_adapter_status_policy)

  // 功能：构造无状态 policy。
  // 输入/输出及副作用：name 设置 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_adapter_status_policy");
    super.new(name);
  endfunction

  // 功能：把 backend 返回的 status 归一为非空、可定位的结果。
  // 输入/输出及副作用：candidate 为 backend status；component/operation 提供诊断上下文；返回原对象或新建 INVALID_STATE。
  // 失败/边界：candidate 非空时原样返回；为空时返回 INVALID_STATE，消息“<component> <operation> returned null status”。
  static function automatic rdma_status normalize(
    rdma_status candidate,
    string component,
    string operation
  );
    if (candidate == null)
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        {component, " ", operation, " returned null status"}
      );
    return candidate;
  endfunction
endclass
