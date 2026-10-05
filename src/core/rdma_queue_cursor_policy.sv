// 目录/层次：核心执行层 core/rdma_queue_cursor_policy.sv。
// 文件职责：提供所有 queue ring 共用的 detached cursor successor 计算，不保存 runtime、
//   pending、ledger 或 backing 状态。
// 主要依赖：仅 UVM 与 int unsigned/bit 标量，不依赖 queue runtime、engine 或 adapter。
// 所有权与生命周期：policy 是无状态值服务；调用方只拥有返回的标量候选值，ring runtime、
//   reservation 与 commit 仍归各自 owner。

// 设计说明：SQ/RQ/CQ/CEQ/AEQ 与 runtime 共用同一环回规则，集中后消除多份 `i + 1 >= depth`
//   实现，同时 geometry admission、错误优先级和提交顺序仍由各 caller 保留。
class rdma_queue_cursor_policy extends uvm_object;
  `rdma_object_utils(rdma_queue_cursor_policy)

  // 功能：构造无状态 cursor policy 对象。
  // 输入/输出及副作用：name 为 UVM 对象名；不保存 depth 或 cursor。
  // 失败/边界：无。
  function new(string name = "rdma_queue_cursor_policy");
    super.new(name);
  endfunction

  // 功能：计算 ring 的下一槽位，末项回零并翻转 wrap。
  // 输入/输出及副作用：depth/source_index/source_wrap 输入；next_index/next_wrap 输出；仅写标量。
  // 失败/边界：depth=0 或 index 越界仍按同一算术给出确定输出，geometry 错误由 caller 报告。
  static function void advance(
      int unsigned depth,
      int unsigned source_index,
      bit source_wrap,
      output int unsigned next_index,
      output bit next_wrap
  );
    next_index = source_index;
    next_wrap = source_wrap;
    if (next_index + 1 >= depth) begin
      next_index = 0;
      next_wrap = ~source_wrap;
    end
    else
      next_index++;
  endfunction
endclass
