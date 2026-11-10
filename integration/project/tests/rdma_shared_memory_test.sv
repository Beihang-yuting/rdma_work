// 目录/层次：integration/project/tests，独立 Host memory 集成回归入口。
// 职责：用真实 host_mem_pool 验证同Host共享、不同Host同GPA隔离与Function私有账本。
// 依赖：UVM、rdma_types_pkg、rdma_host_mem_pkg；不依赖 Intel VIP 或 DUT。
// 所有权与生命周期：测试拥有公共pool和视图，pool持有两个Host manager；退出前释放全部分配，视图只借用manager。
package rdma_shared_memory_test_pkg;
  import uvm_pkg::*;
  import host_mem_pkg::*;
  import rdma_types_pkg::*;
  import rdma_host_mem_pkg::*;
  `include "uvm_macros.svh"

  // 直接访问真实 manager 验证 backing，避免只用两个 adapter 自证数据一致。
  class rdma_shared_memory_test extends uvm_test;
    `uvm_component_utils(rdma_shared_memory_test)

    // 功能：创建独立绑定测试的 UVM 节点，资源延迟到 run_phase 创建。
    // 输入/输出及副作用：name/parent 传给 UVM；构造不分配 Host memory。
    // 失败/边界：不读取 DUT 配置，不要求外部 env；生命周期由 UVM 管理。
    extern function new(string	name = "rdma_shared_memory_test", uvm_component	parent = null);

    // 功能：检查pool唯一manager、双Host同GPA隔离，以及跨Function读写/释放边界。
    // 输入/输出及副作用：phase持有objection；在两个Host同一GPA窗口内分配，验证backing可见性后释放全部分配。
    // 失败/边界：任何契约不符立即 UVM_FATAL；正常完成释放分配并撤销 objection，无等待/超时路径。
    extern task run_phase(uvm_phase	phase);
  endclass

  // 功能：创建独立绑定测试的 UVM 节点，资源延迟到 run_phase 创建。
  // 输入/输出及副作用：name/parent 传给 UVM；构造不分配 Host memory。
  // 失败/边界：不读取 DUT 配置，不要求外部 env；生命周期由 UVM 管理。
  function rdma_shared_memory_test::new(string	name = "rdma_shared_memory_test", uvm_component	parent = null);
    super.new(name, parent);
  endfunction

  // 功能：检查pool唯一manager、双Host同GPA隔离，以及跨Function读写/释放边界。
  // 输入/输出及副作用：phase持有objection；在两个Host同一GPA窗口内分配，验证backing可见性后释放全部分配。
  // 失败/边界：任何契约不符立即 UVM_FATAL；正常完成释放分配并撤销 objection，无等待/超时路径。
  task rdma_shared_memory_test::run_phase(uvm_phase	phase);
    host_mem_pool		pool;
    host_mem_manager	manager;
    host_mem_manager	other_host;
    rdma_host_mem		left;
    rdma_host_mem		right;
    rdma_host_mem		remote;
    rdma_status				status;
    bit [63:0]				address;
    bit [63:0]				right_address;
    bit [63:0]				remote_address;
    byte				bytes[];
    byte				payload[];
    byte				corruption[];

    phase.raise_objection(this);
    pool = host_mem_pool::type_id::create("shared_pool");
    for (int unsigned	h = 0; h < 2; h++) begin
      if (!pool.create_host(h, 64'h1000_0000, 64'h100f_ffff, MODE_BUDDY, 16, HOST_MEM_FIRST_FIT))
        `uvm_fatal("SHARED_MEM", "pool could not create Host memory")
    end
    manager = pool.get_host(0);
    other_host = pool.get_host(1);
    left = rdma_host_mem::type_id::create("left");
    right = rdma_host_mem::type_id::create("right");
    remote = rdma_host_mem::type_id::create("remote");
    left.mem = pool.get_host(0);
    right.mem = pool.get_host(0);
    remote.mem = pool.get_host(1);
    if (left == right || left.mem != manager || right.mem != manager || remote.mem == manager ||
        manager.get_host_id() != 0 || other_host.get_host_id() != 1)
      `uvm_fatal("SHARED_MEM", "pool identity or per-Host sharing failed")

    status = left.alloc(4096, 4096, address);
    if (!status.ok())
      `uvm_fatal("SHARED_MEM", status.convert2string())
    status = right.alloc(4096, 4096, right_address);
    if (!status.ok() || address == right_address)
      `uvm_fatal("SHARED_MEM", "shared allocator overlapped live allocations")
    payload = '{8'h12, 8'h34, 8'h56, 8'h78};
    status = left.write(address, payload);
    if (!status.ok())
      `uvm_fatal("SHARED_MEM", status.convert2string())
    manager.read_mem(address, 4, bytes);
    if (bytes != payload)
      `uvm_fatal("SHARED_MEM", "view writes did not reach shared backing")
    payload[0] = 8'hab;
    manager.write_mem(address, payload);
    status = left.read(address, 4, bytes);
    if (!status.ok() || bytes != payload)
      `uvm_fatal("SHARED_MEM", "manager writes were not visible through owner view")
    status = right.read(address, 4, bytes);
    if (status.code != RDMA_SC_DMA_TRANSLATION || bytes.size() != 0)
      `uvm_fatal("SHARED_MEM", "cross-Function read was accepted")
    // 使用与合法 backing 不同的字节，确保拒绝路径即使错误地执行写入也会被后续读取发现。
    corruption = '{8'hde, 8'had, 8'hbe, 8'hef};
    status = right.write(address, corruption);
    if (status.code != RDMA_SC_DMA_TRANSLATION)
      `uvm_fatal("SHARED_MEM", "cross-Function write was accepted")
    status = right.free(address);
    if (status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_fatal("SHARED_MEM", "cross-Function free was accepted")
    status = left.read(address, 4, bytes);
    if (!status.ok() || bytes != payload)
      `uvm_fatal("SHARED_MEM", "rejected cross-Function operations changed backing")
    status = left.read(address + 4095, 2, bytes);
    if (status.code != RDMA_SC_DMA_TRANSLATION || bytes.size() != 0)
      `uvm_fatal("SHARED_MEM", "read beyond allocation was accepted")
    status = left.read(64'hffff_ffff_ffff_ffff, 4, bytes);
    if (status.code != RDMA_SC_DMA_TRANSLATION || bytes.size() != 0)
      `uvm_fatal("SHARED_MEM", "wrapped address range was accepted")
    if (left.live_allocations() != 1 || right.live_allocations() != 1)
      `uvm_fatal("SHARED_MEM", "Function allocation ledgers were not isolated")
    status = left.free(address);
    if (!status.ok() || left.live_allocations() != 0 || right.live_allocations() != 1)
      `uvm_fatal("SHARED_MEM", "free changed another Function ledger")
    status = left.read(address, 1, bytes);
    if (status.code != RDMA_SC_DMA_TRANSLATION || bytes.size() != 0)
      `uvm_fatal("SHARED_MEM", "freed allocation remained readable")
    status = right.free(right_address);
    if (!status.ok() || right.live_allocations() != 0)
      `uvm_fatal("SHARED_MEM", "right cleanup failed")
    // 两个Host允许数值相同的GPA；在Host1写入不同payload，Host0的分配与数据必须不受影响。
    status = left.alloc(4096, 4096, address);
    if (!status.ok())
      `uvm_fatal("SHARED_MEM", status.convert2string())
    status = remote.alloc(4096, 4096, remote_address);
    if (!status.ok() || remote_address != address)
      `uvm_fatal("SHARED_MEM", "first-fit fixture did not overlap GPA across Hosts")
    status = left.write(address, payload);
    if (!status.ok())
      `uvm_fatal("SHARED_MEM", status.convert2string())
    status = remote.write(remote_address, corruption);
    if (!status.ok())
      `uvm_fatal("SHARED_MEM", status.convert2string())
    manager.read_mem(address, payload.size(), bytes);
    if (bytes != payload)
      `uvm_fatal("SHARED_MEM", "Host1 write corrupted Host0 at the same GPA")
    other_host.read_mem(remote_address, corruption.size(), bytes);
    if (bytes != corruption)
      `uvm_fatal("SHARED_MEM", "Host1 view did not use its pool manager")
    status = remote.free(remote_address);
    if (!status.ok())
      `uvm_fatal("SHARED_MEM", status.convert2string())
    status = left.read(address, payload.size(), bytes);
    if (!status.ok() || bytes != payload)
      `uvm_fatal("SHARED_MEM", "Host1 free changed Host0 allocation")
    status = left.free(address);
    if (!status.ok())
      `uvm_fatal("SHARED_MEM", status.convert2string())
    manager.leak_check();
    other_host.leak_check();
    `uvm_info("SHARED_MEM", "shared pool, overlapping Host GPA and Function isolation passed", UVM_LOW)
    phase.drop_objection(this);
  endtask
endpackage

// 独立 top 使本回归无需修改生产 filelist 或原有 tb_top。
module rdma_shared_memory_top;
  import uvm_pkg::*;
  import rdma_shared_memory_test_pkg::*;
  initial run_test("rdma_shared_memory_test");
endmodule
