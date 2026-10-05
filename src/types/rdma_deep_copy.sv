// 目录：公共类型层 types/rdma_deep_copy.sv。
// 职责：为各层 do_copy/快照实现提供统一的可空对象深拷贝原语，替代每个字段手写的
//   “判空 → clone → $cast → 身份检查 → fatal”样板。
// 依赖：仅依赖 uvm_object::clone 与 UVM 报告宏。
// 所有权与生命周期：返回新建副本，所有权归调用方；源对象只读。

// 设计说明：参数化静态类让调用点保留目标字段的精确类型，同时把失败语义固定为
//   RDMA_COPY_TYPE fatal（与原手写实现一致，测试 report catcher 依赖该 ID）。
class rdma_deep_copy #(type T = uvm_object);

  // 功能：深拷贝可空对象 source；null 源返回 null。
  // 输入/输出及副作用：source 只读；what 为失败诊断文本；返回新副本。
  // 失败/边界：clone 返回 null、类型不符或返回源对象本身时以 RDMA_COPY_TYPE fatal 报告。
  static function T of(T source, string what);
    uvm_object cloned;
    T copy;

    if (source == null)
      return null;
    cloned = source.clone();
    if (cloned == null || !$cast(copy, cloned) || copy == source)
      `uvm_fatal("RDMA_COPY_TYPE", what)
    return copy;
  endfunction

  // 功能：非致命深拷贝：成功时 copy 为与 source 不同的同类型新对象并返回 1。
  // 输入/输出及副作用：source 只读；copy 为输出副本，失败时为 null。
  // 失败/边界：source 为 null、clone 返回 null、类型不符或返回源对象本身时返回 0，
  //   由调用方决定错误码；不发布 UVM 报告。
  static function bit try_of(T source, output T copy);
    uvm_object cloned;

    copy = null;
    if (source == null)
      return 1'b0;
    cloned = source.clone();
    if (cloned == null || !$cast(copy, cloned) || copy == source) begin
      copy = null;
      return 1'b0;
    end
    return 1'b1;
  endfunction
endclass
