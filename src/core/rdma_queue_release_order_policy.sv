// 目录：核心执行层 core/。
// 职责：集中描述 CQ consumer 提交后访问 routed WQ runtime 的唯一锁序，作为纯值 policy。
// 依赖：仅 rdma_queue_runtime_kind_e；不访问 semaphore、ledger 或外部对象。
// 所有权与生命周期：无状态，不保存 queue 引用、不拥有锁；各 runtime 自持 mutable ledger。

// 设计说明：CQ→WQ 是唯一允许的跨 runtime 嵌套方向；policy 只做值约束，
//   lock 获取、gate 生命周期和失败恢复由 rdma_queue_runtime/rdma_queue_data_engine 负责。
class rdma_queue_release_order_policy extends uvm_object;
  `uvm_object_utils(rdma_queue_release_order_policy)

  // 功能：构造无状态 policy。
  // 输入/输出及副作用：name 设置 UVM 名称。
  // 失败/边界：无。
  function new(string name = "rdma_queue_release_order_policy");
    super.new(name);
  endfunction

  // 功能：判断持有 held_kind 锁时 CQ consumer release 能否访问 target_kind 的 WQ runtime。
  // 输入/输出及副作用：只读 kind，返回 bit，无副作用。
  // 失败/边界：仅 CQ→SQ/RQ/SRQ 返回 1；其余组合和未知枚举返回 0，调用方须在 WQ mutation 前拒绝。
  static function bit allows_consumer_release(
      input rdma_queue_runtime_kind_e held_kind,
      input rdma_queue_runtime_kind_e target_kind
  );
    // 用 === 而非 ==/inside：VCS 对 enum 的 X/Z cast 会让普通比较结果被折叠为 1，
    // 逐项 === 保证未知值 fail-closed。
    return (held_kind === RDMA_QUEUE_RUNTIME_CQ) &&
           ((target_kind === RDMA_QUEUE_RUNTIME_SQ) ||
            (target_kind === RDMA_QUEUE_RUNTIME_RQ) ||
            (target_kind === RDMA_QUEUE_RUNTIME_SRQ));
  endfunction
endclass
