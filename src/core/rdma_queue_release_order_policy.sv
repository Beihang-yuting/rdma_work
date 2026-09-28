// 目录：核心执行层 core/。
// 文件职责：集中描述 CQ consumer 提交后访问 routed WQ runtime 的唯一锁序，
//   把跨 queue release 的方向约束从可变 runtime 账本中提取为纯值 policy。
// 主要依赖：只依赖 rdma_queue_runtime_kind_e；不访问 semaphore、pending、cursor、
//   slot ledger、Host-memory、PCIe 或任何外部对象。
// 所有权与生命周期：本文件只提供无状态判断，不保存 queue 引用、不拥有锁，也不
//   改变 runtime 状态；CQ runtime 和 WQ runtime 仍各自拥有自己的 mutable ledger。

// 中文说明：CQ→WQ 是唯一允许的跨 runtime 嵌套方向。policy 只表达“当前持有
// 哪类 runtime lock、准备访问哪类 target”的值约束，具体 lock 获取、gate 生命周期
// 和失败恢复仍由 rdma_queue_runtime/rdma_queue_data_engine 负责。
class rdma_queue_release_order_policy extends uvm_object;
  `uvm_object_utils(rdma_queue_release_order_policy)

  // 功能：构造无状态 release-order policy 对象，建立 UVM 名称但不绑定任何 queue。
  // 输入/输出及副作用：name（输入）；new 返回一个不持有 semaphore、runtime 或
  //   外部 backing 的 helper 对象。
  // 失败/边界：构造成功不代表任意 lock 组合合法；调用方仍必须对 allows_consumer_release
  //   的 false 结果执行 fail-closed，不得把默认值解释为允许嵌套。
  function new(string name = "rdma_queue_release_order_policy");
    super.new(name);
  endfunction

  // 功能：allows_consumer_release 判断 CQ consumer release 是否可以在当前持有的
  //   runtime lock 下访问目标 WQ runtime，统一 CQ→SQ/RQ/SRQ 的跨 queue 锁序。
  // 输入/输出及副作用：held_kind、target_kind 为只读 runtime kind；返回 bit，不
  //   获取或释放 semaphore，不读取 queue 状态，也不修改任何 ledger/cursor/pending。
  // 失败/边界：只有 held_kind= CQ 且 target_kind 属于 SQ、RQ 或 SRQ 时返回 1；
  //   CQ→CQ、WQ→CQ、WQ→WQ、未知枚举和 device-producer target 全部返回 0，调用方
  //   必须在 WQ mutation 前拒绝这些组合以避免锁序反转或错误 owner release。
  static function bit allows_consumer_release(
      input rdma_queue_runtime_kind_e held_kind,
      input rdma_queue_runtime_kind_e target_kind
  );
    // 使用 case equality 而不是普通 equality/inside：VCS 对 enum 的 X/Z
    // cast 可能先完成 4-state 到 enum 的转换，普通比较的 X 结果再被
    // bit 返回值折叠为 1。逐项 === 可确保未知值始终 fail-closed。
    return (held_kind === RDMA_QUEUE_RUNTIME_CQ) &&
           ((target_kind === RDMA_QUEUE_RUNTIME_SQ) ||
            (target_kind === RDMA_QUEUE_RUNTIME_RQ) ||
            (target_kind === RDMA_QUEUE_RUNTIME_SRQ));
  endfunction
endclass
