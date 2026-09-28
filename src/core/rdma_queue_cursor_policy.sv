// 目录/层次：核心执行层 core/rdma_queue_cursor_policy.sv。
// 文件职责：提供所有 queue ring 共用的 detached cursor successor 计算，不保存任何
//   runtime、pending、ledger 或 backing 状态。
// 主要依赖：依赖 UVM；只使用 int unsigned 与 bit 标量，不依赖 queue runtime、
//   queue-data engine 或外部 adapter。
// 所有权与生命周期：policy 是无状态值服务；调用方只拥有返回的标量候选值，ring
//   runtime、reservation、commit 和外部资源仍由各自 engine/runtime owner 管理。

// 设计说明：SQ/RQ/CQ/CEQ/AEQ 和 queue runtime 都需要相同的环回规则。集中到一个
//   detached policy 可以消除多份 `i + 1 >= depth` 实现，同时保留各 caller 自己的
//   geometry admission、错误优先级和提交顺序。
class rdma_queue_cursor_policy extends uvm_object;
  `uvm_object_utils(rdma_queue_cursor_policy)

  // 功能：构造无状态 cursor policy 对象；对象不保存任何 ring depth 或 cursor。
  // 输入/输出及副作用：name（输入）设置 UVM 名称；new 不创建 runtime、pending、
  // ledger 或外部 backing。
  // 失败/边界：构造成功不代表输入 geometry 已授权；调用方必须先完成 depth/index
  // gate，不能把本函数输出直接当作已提交 reservation。
  function new(string name = "rdma_queue_cursor_policy");
    super.new(name);
  endfunction

  // 功能：advance 计算 queue producer/consumer 的下一槽位值，统一处理 ring 末项
  //   回零和 wrap 翻转。
  // 输入/输出及副作用：depth/source_index/source_wrap 为输入；next_index/next_wrap
  //   为输出；函数只写标量，不访问 runtime、pending、backing、ledger 或 scheduler。
  // 失败/边界：depth=0 或 source_index 越界时仍按兼容算术规则给出确定输出，保留
  //   caller 自己报告 geometry 错误的顺序；该输出不构成 reservation 或 commit 证明。
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
