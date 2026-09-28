// 目录/层次：适配器接口层 adapter/rdma_adapter_status_policy.sv。
// 文件职责：集中定义外部 adapter 返回 null status 时的 fail-closed 归一化规则，
//   让 Host-memory API 和具体 Host-memory adapter 共用同一份错误边界。
// 主要依赖：依赖 rdma_types_pkg 中的 rdma_status；不访问 Host-memory、PCIe、
//   network、manager、router 或任何可变账本。
// 所有权与生命周期：policy 只创建 detached rdma_status 值；不保存调用方引用，
//   不取得外部资源所有权，也不改变下游 adapter 的生命周期。

// 中文设计说明：adapter 的公共契约要求所有 backend 调用都返回非空 rdma_status。
// null 是下游实现的契约违例，不能被 caller 当成成功或继续读取 output。把错误构造
// 独立成纯值 policy，避免基类和 concrete adapter 维护两套稍有差异的诊断前缀。
class rdma_adapter_status_policy extends uvm_object;
  `uvm_object_utils(rdma_adapter_status_policy)

  // 功能：构造无状态 adapter status policy，不创建 backend、mapping 或 adapter ledger。
  // 输入/输出及副作用：name（输入）设置 UVM 对象名称；new 只调用基类构造并返回，
  //   不修改任何外部资源或状态。
  // 失败/边界：构造成功不代表某次 backend 调用有效；调用方仍必须把 normalize() 的
  //   非空结果作为唯一 status 入口，不能因为 policy 存在而忽略 adapter output。
  function new(string name = "rdma_adapter_status_policy");
    super.new(name);
  endfunction

  // 功能：normalize 将 backend 返回的 status 统一转换为非空、可定位的 detached 结果。
  // 输入/输出及副作用：candidate（输入）是 backend status；component 与 operation
  //   提供诊断上下文；返回 candidate 原对象或新建 INVALID_STATE status，不修改
  //   mapping、ledger、cursor、外部 backing 或 adapter 生命周期。
  // 失败/边界：candidate 非空时保持原对象和错误码不变；candidate 为空时返回
  //   RDMA_SC_INVALID_STATE，消息为“<component> <operation> returned null status”，
  //   禁止返回 null、OK 或隐式重试。
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
