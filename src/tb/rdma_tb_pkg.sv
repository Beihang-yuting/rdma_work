// 目录：验证组件层 tb/rdma_tb_pkg.sv。
// 层：验证组件。
// 职责：汇总 seq→驱动模型→设备模型→报文→内存验证流程的 UVM 组件：verb agent、wire、记分板与 env。
// 依赖：rdma_types/model/codec/adapter、rdma_dev/rdma_drv package 与 UVM；不依赖外部 VIP
//   （net_packet 等由测试经 wire 子类接入）。
// 所有权：package 本身不持有运行资源；组件只借用节点配置中的设备、驱动与缓冲。
// 生命周期：随仿真编译单元存在。
package rdma_tb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_codec_pkg::*;
  import rdma_adapter_pkg::*;
  import rdma_dev_pkg::*;
  import rdma_drv_pkg::*;

  typedef class rdma_verb_monitor;

  `include "rdma_tb_items.sv"
  `include "rdma_tb_node_cfg.sv"
  `include "rdma_wire.sv"
  `include "rdma_verb_agent.sv"
  `include "rdma_tb_scoreboard.sv"
  `include "rdma_tb_env.sv"
  `include "rdma_verb_sequences.sv"
endpackage
