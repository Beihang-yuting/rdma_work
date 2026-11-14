// 目录/层次：src/adapters/pcie；RDMA 到公共 PCIe transport 的边界。
// 职责：消费 dpu_common 冻结 BAR target，以已有 pcie_tl_reg_seq 下发驱动写入。
// 依赖：rdma_drv_pkg、dpu_pcie_pkg、pcie_tl_pkg；不依赖 VIO 或具体项目 env。
// 所有权/生命周期：适配器只借用 map/sequencer；调用者确保它们覆盖全部事务，BAR authority 保持在 dpu_common。
package rdma_pcie_pkg;
  import uvm_pkg::*;
  import rdma_types_pkg::*;
  import rdma_drv_pkg::*;
  import dpu_resource_pkg::*;
  import dpu_pcie_pkg::*;
  import pcie_tl_pkg::*;
  `include "uvm_macros.svh"

// Intel RC 的 RDMA BAR 适配层：只借用 dpu_common 的冻结目标和 pcie_tl_vip 的 RC sequencer，
// 不创建 RDMA 专用 PCIe transport，也不拥有 BAR、RC 或 Host memory。每次写入都重新校验
// target 的 snapshot/generation，避免 restore/rebuild 后沿用旧 Function 路由。
class rdma_pcie_bar extends rdma_drv_bar;
  `uvm_object_utils(rdma_pcie_bar)

  dpu_pcie_bar_map             map;
  dpu_bar_target_t             target;
  uvm_sequencer #(pcie_tl_tlp) sequencer;

  // 功能：构造未绑定的 Intel RC BAR 适配器。
  // 输入/输出及副作用：name 传给 UVM；map、target 和 sequencer 保持空状态，不创建 PCIe 组件。
  // 失败/边界：绑定完成前 write64 返回 INVALID_STATE；适配器不拥有外部 map 或 sequencer。
  extern function new(string name = "rdma_pcie_bar");

  // 功能：把 RDMA 驱动的 BAR0 8B 写转换为 pcie_tl_reg_seq，并通过目标 Host 的 Intel RC 发送。
  // 输入/输出及副作用：offset/value 为驱动寄存器访问；status 返回 PCIe posted write 的结果。
  // 失败/边界：空绑定、过期/越界 BAR、非法 PCIe 请求或 RC 发送错误均不发出后续事务并返回失败。
  extern virtual task write64(bit [63:0] offset, bit [63:0] value, output rdma_status status);
endclass

  // 功能：构造未绑定的公共 PCIe BAR 适配器。
  // 输入/输出及副作用：name 传给父类，map/sequencer 初始为空；不创建外部资源。
  // 失败/边界：绑定完成前 write64 返回 INVALID_STATE。
  function rdma_pcie_bar::new(string name = "rdma_pcie_bar");
    super.new(name);
    map       = null;
    sequencer = null;
  endfunction

  // 功能：校验冻结 BAR target 后将驱动 8 字节写入发送到目标 Host RC。
  // 输入/输出及副作用：offset/value 指定写入，status 输出 posted write 的发送结果。
  // 失败/边界：空绑定、过期/越界 target 拒绝；发送超时返回 TIMEOUT，其他传输失败返回 PCIE_COMPLETION。
  task rdma_pcie_bar::write64(bit [63:0] offset, bit [63:0] value, output rdma_status status);
    pcie_tl_reg_seq request;
    bit [63:0]      address;
    string          why;

    if (map == null || sequencer == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "Intel RDMA BAR has no RC binding");
      return;
    end
    if (!map.check_range(target, offset, 8, address, why)) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, why);
      return;
    end

    request          = pcie_tl_reg_seq::type_id::create({get_name(), "_write"});
    request.is_write = 1;
    request.addr     = address;
    request.len      = 8;
    request.mask     = 0;
    request.wdata    = value;
    request.start(sequencer);

    case (request.status)
      PCIE_RW_OK:
        status = rdma_status::success();
      PCIE_RW_TIMEOUT:
        status = rdma_status::make(RDMA_SC_TIMEOUT, request.error_msg);
      default:
        status = rdma_status::make(RDMA_SC_PCIE_COMPLETION, request.error_msg);
    endcase
  endtask
endpackage
