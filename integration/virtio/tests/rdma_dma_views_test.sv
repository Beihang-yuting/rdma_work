// 目录/层次：integration/virtio/tests；公共 RC 多业务 DMA 视图回归。
// 职责：验证直接 RDMA 地址、VIO 翻译、同 Requester 共存、权限及地址所有权冲突。
// 依赖：真实 host_mem、PCIe RC、VIO IOMMU 与 RDMA ledger；无 DUT/链路仿真依赖。
// 所有权/生命周期：test 拥有 backing/账本/IOMMU，RC 借用 view；结束前释放映射和分配。
package rdma_dma_views_test_pkg;
  import uvm_pkg::*;
  import host_mem_pkg::*;
  import pcie_tl_pkg::*;
  import virtio_net_pkg::*;
  import rdma_types_pkg::*;
  import rdma_host_mem_pkg::*;
  `include "uvm_macros.svh"

  // 捕获真实 RC responder 的 Completion，避免测试依赖链路和 DUT。
  class dma_capture_driver extends pcie_tl_rc_driver;
    `uvm_component_utils(dma_capture_driver)
    pcie_tl_cpl_tlp	completion;
    // 功能：创建测试 RC；实际 memory/read observer 仍由父类管理。
    // 输入/输出及副作用：name/parent 传给父类，无额外资源分配。
    // 失败/边界：不配置链路；测试必须在 build 完成后调用 receive。
    extern function new(string name = "dma_capture_driver", uvm_component parent = null);
    // 功能：捕获 responder 生成的 Completion，作为读取结果断言。
    // 输入/输出及副作用：tlp 转为 completion 句柄；不发送线上流量。
    // 失败/边界：非 Completion 立即 fatal；本测试只产生单分片四字节读取。
    extern virtual task send_tlp(pcie_tl_tlp tlp);
    // 功能：保持 fixture driver 空闲，避免无 sequencer 的捕获 driver 进入父类取 item 流程。
    // 输入/输出及副作用：phase 生命周期内不发送请求、不消费队列，只让 responder 由测试直接调用。
    // 失败/边界：该 driver 不支持 sequence 驱动；若误接 sequencer，仍不会替代正常 RC driver。
    extern virtual task run_phase(uvm_phase phase);
  endclass

  // 仅验证公共 RC 的 MSI-X 分发契约，不代表 VIO 或 RDMA 的业务中断实现。
  class capture_msix_sink extends pcie_tl_msix_sink;
    `uvm_object_utils(capture_msix_sink)
    int unsigned count;

    // 功能：构造只统计消费次数的 MSI-X sink。
    // 输入/输出及副作用：name 传给 UVM，count 从零开始；不保存 RC 或 Host 引用。
    // 失败/边界：sink 只接受公共 RC 已完成地址/data 匹配的四字节写。
    function new(string name = "capture_msix_sink");
      super.new(name);
      count = 0;
    endfunction

    // 功能：记录一笔公共 RC 分发的 MSI-X Memory Write。
    // 输入/输出及副作用：递增 count；不修改 request、Host memory 或 Completion 状态。
    // 失败/边界：request 为空时拒绝，其余已匹配请求均成功消费。
    virtual function bit consume(pcie_tl_mem_tlp request, output string why);
      why = "MSI-X capture sink received a null request";
      if (request == null) begin
        return 0;
      end
      count++;
      why = "";
      return 1;
    endfunction
  endclass

  class rdma_dma_views_test extends uvm_test;
    `uvm_component_utils(rdma_dma_views_test)
    dma_capture_driver	rc;
    // 功能：创建 DMA 隔离回归 test，资源延迟到 run_phase。
    // 输入/输出及副作用：name/parent 交给 UVM；不建立映射或分配。
    // 失败/边界：无外部配置要求。
    extern function new(string name = "rdma_dma_views_test", uvm_component parent = null);
    // 功能：创建继承真实 responder 的捕获 RC。
    // 输入/输出及副作用：phase 传给父类，rc 由 UVM 管理。
    // 失败/边界：不需要 adapter；send_tlp 由 fixture 捕获。
    extern function void build_phase(uvm_phase phase);
    // 功能：执行双业务 DMA、未知 Requester、跨 Function、权限和冲突断言。
    // 输入/输出及副作用：phase 持有 objection；创建并清理 manager 分配及 IOMMU 映射。
    // 失败/边界：契约不符 fatal；没有异步等待或超时路径。
    extern task run_phase(uvm_phase phase);
  endclass

  // 功能：初始化捕获 RC 组件。
  // 输入/输出及副作用：name/parent 传给父类；completion 默认 null。
  // 失败/边界：实际 responder 端口由父类 build 创建。
  function dma_capture_driver::new(string name = "dma_capture_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  // 功能：记录 RC 生成的读取 Completion。
  // 输入/输出及副作用：tlp 保存到 completion，测试立即读取 payload。
  // 失败/边界：类型不是 Completion 时 fatal，不静默丢包。
  task dma_capture_driver::send_tlp(pcie_tl_tlp tlp);
    if (!$cast(completion, tlp)) `uvm_fatal("DMA_VIEWS", "expected Completion")
  endtask
  // 功能：让无 sequencer 的 fixture driver 保持运行，供测试 task 直接调用 handle_request。
  // 输入/输出及副作用：phase 期间仅等待时间，不修改 RC pending、Tag 或 Host memory。
  // 失败/边界：测试结束由 UVM phase 关闭；该实现不接收 sequence item。
  task dma_capture_driver::run_phase(uvm_phase phase);
    forever #1ns;
  endtask
  // 功能：构造双业务 DMA 测试对象。
  // 输入/输出及副作用：name/parent 传给父类，rc 在 build 创建。
  // 失败/边界：构造不访问 Host memory。
  function rdma_dma_views_test::new(string name = "rdma_dma_views_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  // 功能：创建捕获 RC 并启用公共 Host memory responder。
  // 输入/输出及副作用：phase 传给父类；rc.use_unified_mem 置位。
  // 失败/边界：不使用 legacy mem 回退，所有访问必须命中注册 view。
  function void rdma_dma_views_test::build_phase(uvm_phase phase);
    super.build_phase(phase);
    rc = dma_capture_driver::type_id::create("rc", this);
    rc.use_unified_mem = 1;
  endfunction
  // 功能：验证同一 Requester 下 VIO IOVA 与 RDMA Host 地址的唯一所有权及读写结果。
  // 输入/输出及副作用：phase 持有 objection；操作真实 backing、ledger、IOMMU 并清理分配。
  // 失败/边界：所有负向检查使用纯预检，不依赖 UVM_ERROR 降级；成功后输出 DMA_VIEWS_PASS。
  task rdma_dma_views_test::run_phase(uvm_phase phase);
    host_mem_manager	backing;
    rdma_host_mem	left;
    rdma_host_mem	right;
    virtio_iommu_model	iommu;
    virtio_host_mem_view	vio;
    host_mem_api	selected;
    pcie_tl_mem_tlp	r;
    rdma_status	status;
    string	why;
    bit [63:0]	addr;
    bit [63:0]	other;
    bit [63:0]	vio_gpa;
    bit [63:0]	iova;
    bit [63:0]	collision;
    byte	bytes[];
    capture_msix_sink	msix_sink;
    pcie_tl_mem_tlp	msix_write;

    phase.raise_objection(this);
    backing = host_mem_manager::type_id::create("backing");
    backing.init_region(64'h1000_0000, 64'h100f_ffff, MODE_BUDDY, 16);
    backing.set_host_id(0);
    left = rdma_host_mem::type_id::create("left");
    right = rdma_host_mem::type_id::create("right");
    if (!left.bind_host_mem(backing, why) || !right.bind_host_mem(backing, why))
      `uvm_fatal("DMA_VIEWS", why)
    status = left.alloc(4096, 4096, addr);
    if (!status.ok()) `uvm_fatal("DMA_VIEWS", status.convert2string())
    status = right.alloc(4096, 4096, other);
    if (!status.ok()) `uvm_fatal("DMA_VIEWS", status.convert2string())
    vio_gpa = backing.alloc(4096, 4096);
    iommu = virtio_iommu_model::type_id::create("iommu");
    if (!iommu.configure_iova_aperture(64'h1000_0000, 64'h3000_0000, IOMMU_IOVA_FIRST_FIT, why))
      `uvm_fatal("DMA_VIEWS", why)
    iova = iommu.map_fixed_for_host(0, 16'h0123, vio_gpa, 4096, DMA_TO_DEVICE, 64'h2000_0000);
    if (iova != 64'h2000_0000) `uvm_fatal("DMA_VIEWS", "VIO mapping failed")
    vio = virtio_host_mem_view::type_id::create("vio");
    if (!vio.configure(backing, iommu, 0, 16'h0123, why) ||
        !rc.register_dma_view(16'h0123, vio, why) ||
        !rc.register_dma_view(16'h0123, left.dma_view, why)) `uvm_fatal("DMA_VIEWS", why)
    msix_sink = capture_msix_sink::type_id::create("msix_sink");
    if (!rc.register_msix_sink(16'h0456, 64'hfee0_0000, 32'h40, msix_sink, why))
      `uvm_fatal("DMA_VIEWS", why)
    msix_write = pcie_tl_mem_tlp::type_id::create("msix_write");
    msix_write.kind = TLP_MEM_WR;
    msix_write.fmt = FMT_3DW_WITH_DATA;
    msix_write.type_f = TLP_TYPE_MEM_RD;
    msix_write.requester_id = 16'h0456;
    msix_write.addr = 64'hfee0_0000;
    msix_write.length = 1;
    msix_write.first_be = 4'hf;
    msix_write.last_be = 0;
    msix_write.payload = '{8'h40, 8'h00, 8'h00, 8'h00};
    rc.handle_request(msix_write);
    if (msix_sink.count != 1)
      `uvm_fatal("DMA_VIEWS", "generic MSI-X sink did not consume the message write")
    r = pcie_tl_mem_tlp::type_id::create("request");
    r.kind = TLP_MEM_WR;
    r.fmt = FMT_3DW_WITH_DATA;
    r.type_f = TLP_TYPE_MEM_RD;
    r.requester_id = 16'h0123;
    r.addr = addr;
    r.length = 1;
    r.first_be = 4'hf;
    r.last_be = 0;
    r.payload = '{8'h12, 8'h34, 8'h56, 8'h78};
    if (!rc.select_dma_view(r, selected, why) || selected != left.dma_view) `uvm_fatal("DMA_VIEWS", why)
    rc.handle_request(r);
    backing.read_mem(addr, 4, bytes);
    if (bytes.size() != 4 || bytes[0] != 8'h12 || bytes[1] != 8'h34 || bytes[2] != 8'h56 || bytes[3] != 8'h78) `uvm_fatal("DMA_VIEWS", "direct DMA write failed")
    r.kind = TLP_MEM_RD;
    r.fmt = FMT_3DW_NO_DATA;
    rc.handle_request(r);
    if (rc.completion == null || rc.completion.payload != r.payload) `uvm_fatal("DMA_VIEWS", "direct DMA read failed")
    r.addr = other;
    if (rc.select_dma_view(r, selected, why)) `uvm_fatal("DMA_VIEWS", "cross Function accepted")
    r.addr = addr;
    r.requester_id = 16'h7777;
    if (rc.select_dma_view(r, selected, why)) `uvm_fatal("DMA_VIEWS", "unknown Requester accepted")
    r.requester_id = 16'h0123;
    r.addr = iova;
    backing.write_mem(vio_gpa, bytes);
    rc.handle_request(r);
    if (rc.completion.payload != r.payload || vio.read_count() != 4) `uvm_fatal("DMA_VIEWS", "VIO translated read failed")
    r.kind = TLP_MEM_WR;
    r.fmt = FMT_3DW_WITH_DATA;
    if (rc.select_dma_view(r, selected, why)) `uvm_fatal("DMA_VIEWS", "VIO read-only mapping accepted write")
    collision = iommu.map_fixed_for_host(0, 16'h0123, vio_gpa, 4096, DMA_TO_DEVICE, addr);
    if (collision != addr) `uvm_fatal("DMA_VIEWS", "collision fixture failed")
    r.addr = addr;
    if (rc.select_dma_view(r, selected, why) || why != "ambiguous DMA address ownership")
      `uvm_fatal("DMA_VIEWS", "overlap bypassed VIO permission via RDMA")
    iommu.unmap_for_host(0, 16'h0123, collision);
    iommu.unmap_for_host(0, 16'h0123, iova);
    status = left.free(addr);
    if (!status.ok() || rc.select_dma_view(r, selected, why)) `uvm_fatal("DMA_VIEWS", "freed RDMA address remains accessible")
    status = right.free(other);
    if (!status.ok()) `uvm_fatal("DMA_VIEWS", status.convert2string())
    backing.free(vio_gpa);
    backing.leak_check();
    `uvm_info("DMA_VIEWS_PASS", "direct RDMA + VIO translation, isolation, permission and overlap passed", UVM_LOW)
    phase.drop_objection(this);
  endtask
endpackage

module rdma_dma_views_top;
  import uvm_pkg::*;
  import rdma_dma_views_test_pkg::*;
  initial run_test("rdma_dma_views_test");
endmodule
