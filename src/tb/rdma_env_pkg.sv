// 目录：验证组件层 tb/rdma_env_pkg.sv。
// 层：验证组件。
// 职责：RDMA UVM env 包：配置、资源层、源数据生成、事务、控制面/数据面 agent、链路、scoreboard
//   （期望内存 + 期望完成）、env 与虚拟序列。
// 依赖：rdma_types/model/codec/dev/drv、外部组件包（rdma_host_mem_pkg、rdma_dpu_adapter_pkg、
//   rdma_netpkt_pkg：负载生成与帧编解码）、UVM。
// 所有权：包本身不持有运行资源。
// 生命周期：随编译单元存在。
package rdma_env_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import rdma_types_pkg::*;
  import rdma_model_pkg::*;
  import rdma_codec_pkg::*;
  import rdma_host_mem_pkg::*;
  import rdma_dev_pkg::*;
  import rdma_drv_pkg::*;
  import dpu_resource_pkg::*;
  import rdma_dpu_adapter_pkg::*;
  import rdma_netpkt_pkg::*;

  typedef byte unsigned rdma_byte_q[$];

  `include "rdma_env_cfg.sv"
  `include "rdma_res.sv"
  `include "rdma_data_gen.sv"
  `include "rdma_env_items.sv"
  `include "rdma_link.sv"
  `include "rdma_mem_model.sv"
  `include "rdma_expect.sv"
  `include "rdma_ctrl_agent.sv"
  `include "rdma_verb_agent.sv"
  `include "rdma_scoreboard.sv"
  `include "rdma_proto_checker.sv"
  `include "rdma_coverage.sv"
  `include "rdma_env.sv"
  `include "rdma_vseqs.sv"
  `include "rdma_scenario_vseqs.sv"
endpackage
