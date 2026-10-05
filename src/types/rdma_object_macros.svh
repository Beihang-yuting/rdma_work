// 目录：公共类型层 types/rdma_object_macros.svh。
// 职责：定义 rdma_object_utils：在 `uvm_object_utils 基础上提供别名安全的 clone()。
// 依赖：展开点须已 import uvm_pkg 并包含 uvm_macros.svh。
// 所有权与生命周期：纯文本宏，不持有状态。
// 设计说明：UVM 1.2 的 uvm_object::copy 在一次顶层复制期间以源对象为键记录 global copy map，
//   同一源对象在该次复制中被第二次 clone（列表元素别名、多个字段指向同一对象、跨层共享）时 copy 直接返回，
//   得到全默认值的对象而不报错。本 clone() 用 create() 保持动态类型，直接执行字段自动化与 do_copy，
//   不经 copy map；测试子类覆盖 clone() 后调用 super.clone() 的故障注入语义保持不变。
`ifndef RDMA_OBJECT_MACROS_SVH
`define RDMA_OBJECT_MACROS_SVH

`define rdma_alias_safe_clone \
  virtual function uvm_object clone(); \
    uvm_object copy_value; \
    copy_value = create(get_name()); \
    if (copy_value == null) \
      return null; \
    copy_value.__m_uvm_field_automation(this, UVM_COPY, ""); \
    copy_value.do_copy(this); \
    return copy_value; \
  endfunction

`define rdma_object_utils(T) \
  `uvm_object_utils(T) \
  `rdma_alias_safe_clone

`endif
