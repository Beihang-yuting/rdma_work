// 目录：测试层 tests/integration/。
// 职责：验证 RDMA SR-IOV 前门枚举、64-bit PF/VF BAR 分配、Function 路由和失败回滚。
// 依赖：rdma_sriov_enumerator、rdma_pcie_bar_allocator、rdma_pcie_work_adapter、
//   pcie_tl_func_manager、pcie_tl_bar_decoder 与 UVM；测试不修改外部 PCIe 源码。
// 所有权与生命周期：测试拥有本地 PCIe fixture 和 allocator；adapter/sequence 仅保存
//   fixture 的非拥有引用，测试结束时由 UVM 释放对象。

// 功能：为 SR-IOV 失败路径提供可控的 PCIe fault injection。
// 输入/输出及副作用：通过 fail_* 字段选择一次性或按调用序号拒绝 cfg/MMIO
//   操作；正常调用转发给真实 rdma_pcie_work_adapter，不修改 canonical manager。
// 失败/边界：注入状态只影响当前 adapter 实例；测试必须在每个场景使用新的
//   manager/adapter，避免残留计数或配置状态串到下一用例。
class rdma_sriov_fault_pcie_adapter extends rdma_pcie_work_adapter;
  `uvm_object_utils(rdma_sriov_fault_pcie_adapter)

  bit fail_vf_vendor_read;
  bit fail_decode_bar_once;
  int fail_cfg_read_at;
  int fail_cfg_write_at;
  int cfg_read_count;
  int cfg_write_count;

  // 功能：构造故障注入 adapter 并清零计数器。
  // 输入/输出及副作用：name（输入）；仅初始化本地 fault 控制字段。
  // 失败/边界：构造成功不代表后端已 configure，所有业务入口仍沿用基类检查。
  function new(string name = "rdma_sriov_fault_pcie_adapter");
    super.new(name);
    fail_vf_vendor_read = 1'b0;
    fail_decode_bar_once = 1'b0;
    fail_cfg_read_at = 0;
    fail_cfg_write_at = 0;
    cfg_read_count = 0;
    cfg_write_count = 0;
  endfunction

  // 功能：在指定 cfg read 调用上注入 PCIE completion 错误，覆盖 BAR sizing
  //   和 VF Vendor/Device 读取失败路径。
  // 输入/输出及副作用：target/offset（输入）、data/status（输出）；注入时不
  //   修改 config image，否则调用基类实现完成真实读取。
  // 失败/边界：fail_cfg_read_at 从 1 开始计数；fail_vf_vendor_read 只拒绝
  //   offset=0 的 VF 读取；输出 data 保持全 1，模拟 Unsupported Request。
  virtual task cfg_read32(
    rdma_bdf_t target,
    rdma_cfg_offset_t offset,
    output bit [31:0] data,
    output rdma_status status
  );
    cfg_read_count++;
    if ((fail_cfg_read_at > 0 && cfg_read_count == fail_cfg_read_at) ||
        (fail_vf_vendor_read && offset.value == 12'h000)) begin
      data = 32'hffff_ffff;
      status = rdma_status::make(RDMA_SC_PCIE_COMPLETION,
                                 "injected PCIe config read failure");
      status.source_engine = RDMA_ENGINE_PCIE;
      return;
    end
    super.cfg_read32(target, offset, data, status);
  endtask

  // 功能：在指定 cfg write 调用上注入 PCIE completion 错误，验证枚举器在
  //   BAR/NumVFs/Control 编程任一阶段都能回滚。
  // 输入/输出及副作用：target/offset/data/byte_enable（输入）、status（输出）；
  //   注入时不更新 manager 或配置代理，否则调用基类提交真实写入。
  // 失败/边界：fail_cfg_write_at 从 1 开始计数；零表示不按序号注入。
  virtual task cfg_write32(
    rdma_bdf_t target,
    rdma_cfg_offset_t offset,
    bit [31:0] data,
    bit [3:0] byte_enable,
    output rdma_status status
  );
    cfg_write_count++;
    if (fail_cfg_write_at > 0 && cfg_write_count == fail_cfg_write_at) begin
      status = rdma_status::make(RDMA_SC_PCIE_COMPLETION,
                                 "injected PCIe config write failure");
      status.source_engine = RDMA_ENGINE_PCIE;
      return;
    end
    super.cfg_write32(target, offset, data, byte_enable, status);
  endtask

  // 功能：在 VF BAR 路由校验点注入 decode_bar 错误，验证已分配 lease 和
  //   SR-IOV enable 状态会被完整清理。
  // 输入/输出及副作用：address（输入）、result/status（输出）；注入时 result
  //   清零且不访问 decoder，否则调用基类完成真实 BAR 解码。
  // 失败/边界：fail_decode_bar_once 只触发一次，便于确认 sequence 不会隐式重试。
  virtual function rdma_status decode_bar(
    rdma_bar_addr_t address,
    output rdma_bar_decode result
  );
    if (fail_decode_bar_once) begin
      fail_decode_bar_once = 1'b0;
      result = null;
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "injected BAR decoder failure");
    end
    return super.decode_bar(address, result);
  endfunction
endclass

class rdma_sriov_enumeration_test extends uvm_test;
  `uvm_component_utils(rdma_sriov_enumeration_test)

  pcie_tl_func_manager func_mgr;
  pcie_tl_bar_decoder bar_decoder;
  pcie_tl_config_proxy config_proxy;
  rdma_pcie_work_adapter pcie_adapter;
  rdma_pcie_bar_allocator allocator;
  rdma_sriov_enumerator enumerator;

  // 功能：构造 SR-IOV 枚举测试组件，只建立 UVM 层级，不分配 PCIe/ BAR 资源。
  // 输入/输出及副作用：name、parent（输入）；调用 super.new 并保留空 fixture 句柄。
  // 失败/边界：构造成功不表示 adapter 已配置；run_phase 必须先完成 build_fixture。
  function new(string name = "rdma_sriov_enumeration_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 build 阶段创建 manager、proxy、decoder、adapter、allocator 和 sequence。
  // 输入/输出及副作用：phase（输入）；只创建本测试拥有的对象，不触发配置事务。
  // 失败/边界：任一对象为空时由后续 build_fixture 以 UVM fatal 暴露，而不伪造成功。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    func_mgr = pcie_tl_func_manager::type_id::create("func_mgr");
    func_mgr.cfg_profile = PCIE_CFG_PROFILE_DPU_20F9_501X;
    bar_decoder = pcie_tl_bar_decoder::type_id::create("bar_decoder");
    config_proxy = pcie_tl_config_proxy::type_id::create("config_proxy", this);
    pcie_adapter = rdma_pcie_work_adapter::type_id::create("pcie_adapter");
    allocator = rdma_pcie_bar_allocator::type_id::create("allocator");
    enumerator = rdma_sriov_enumerator::type_id::create("enumerator");
  endfunction

  // 功能：把 manager 的 VF RID 参数改为非默认 offset/stride，并同步每个 VF context。
  // 输入/输出及副作用：pf_idx、first_offset、stride（输入）；更新 canonical manager 的
  //   SR-IOV 快照、VF BDF 和 LUT 前的上下文值，不直接发送配置事务。
  // 失败/边界：参数为零或索引越界时触发 UVM fatal，避免用错误 BDF 继续枚举。
  task automatic set_vf_rid_geometry(int pf_idx,
                                     bit [15:0] first_offset,
                                     bit [15:0] stride);
    if (pf_idx < 0 || pf_idx >= func_mgr.num_pfs ||
        first_offset == 0 || stride == 0)
      `uvm_fatal("RID_GEOMETRY", "invalid test VF RID geometry")
    func_mgr.sriov_caps[pf_idx].first_vf_offset = first_offset;
    func_mgr.sriov_caps[pf_idx].vf_stride = stride;
    func_mgr.sriov_caps[pf_idx].num_vfs = 0;
    func_mgr.sriov_caps[pf_idx].vf_enable = 0;
    for (int vf = 0; vf < func_mgr.max_vfs_per_pf; vf++) begin
      func_mgr.vf_ctx[pf_idx][vf].bdf =
        func_mgr.sriov_caps[pf_idx].get_vf_rid(vf);
      func_mgr.vf_ctx[pf_idx][vf].enabled = 0;
    end
    func_mgr.sync_sriov_cfg_image(pf_idx);
  endtask

  // 功能：建立双 PF、未启用 VF 的 canonical PCIe fixture，并配置 RDMA adapter 和全局
  //   64-bit BAR allocator，作为两个 PF 依次枚举的共同环境。
  // 输入/输出及副作用：无显式参数；更新测试 fixture 成员和 manager LUT。
  // 失败/边界：配置失败立即 fatal；fixture 不创建影子 Function/BAR 表。
  task automatic build_fixture();
    rdma_status status;

    func_mgr.build(2, 8);
    func_mgr.disable_vfs(0);
    func_mgr.disable_vfs(1);
    set_vf_rid_geometry(0, 16'h0005, 16'h0003);
    set_vf_rid_geometry(1, 16'h0006, 16'h0003);
    bar_decoder.func_mgr = func_mgr;
    config_proxy.func_mgr = func_mgr;
    config_proxy.multi_function_mode = 1'b1;
    status = pcie_adapter.configure(func_mgr, bar_decoder, config_proxy, 1'b1);
    if (!status.ok())
      `uvm_fatal("PCIE_ADAPTER", status.convert2string())
    status = allocator.configure('{value:64'h0000_0001_0000_0000},
                                 64'h0000_0000_1000_0000);
    if (!status.ok())
      `uvm_fatal("BAR_ALLOCATOR", status.convert2string())
    status = enumerator.configure(pcie_adapter, allocator);
    if (!status.ok())
      `uvm_fatal("ENUMERATOR", status.convert2string())
  endtask

  // 功能：枚举 PF0/PF1 各两个 VF，检查 offset/stride 生成的 BDF、BAR 对齐和跨 PF 不重叠。
  // 输入/输出及副作用：调用前门配置 sequence；成功时输出两个 detached Function 快照数组。
  // 失败/边界：任一 config、BAR decode 或 Function identity 不一致均报告 UVM error。
  task automatic test_two_pf_enumeration();
    rdma_pcie_function_info discovered0[$];
    rdma_pcie_function_info discovered1[$];
    rdma_status status;
    bit [15:0] expected_raw;

    enumerator.enumerate_and_configure_pf(
      '{segment:16'h0, bus:8'h1, device:5'h0, function_num:3'h0},
      2, discovered0, status);
    if (!status.ok() || discovered0.size() != 2)
      `uvm_error("ENUM_PF0", status.convert2string())
    foreach (discovered0[i]) begin
      expected_raw = func_mgr.pf_ctx[0].bdf + 16'h0005 + i * 16'h0003;
      if (rdma_bdf_requester_id(discovered0[i].bdf) != expected_raw ||
          discovered0[i].bar[0].size == 0 ||
          (discovered0[i].bar[0].base.value &
           (discovered0[i].bar[0].size - 1'b1)) != 0)
        `uvm_error("VF0_BAR", $sformatf("invalid VF0[%0d] identity/BAR", i))
    end

    enumerator.enumerate_and_configure_pf(
      '{segment:16'h0, bus:8'h1, device:5'h0, function_num:3'h1},
      2, discovered1, status);
    if (!status.ok() || discovered1.size() != 2)
      `uvm_error("ENUM_PF1", status.convert2string())
    if (discovered0.size() == 2 && discovered1.size() == 2 &&
        discovered0[0].bar[0].base.value == discovered1[0].bar[0].base.value)
      `uvm_error("BAR_OVERLAP", "two PF VF BAR aggregates overlap")
    if (func_mgr.sriov_caps[0].num_vfs != 2 ||
        !func_mgr.sriov_caps[0].vf_enable ||
        func_mgr.sriov_caps[1].num_vfs != 2 ||
        !func_mgr.sriov_caps[1].vf_enable)
      `uvm_error("SRIOV_STATE", "PF SR-IOV state was not enabled")
  endtask

  // 功能：使用过小的 allocator 触发枚举失败，确认 VFE/NumVFs 被清理且其他 PF 未被修改。
  // 输入/输出及副作用：创建独立 sequence/allocator 并执行一次失败枚举；原有 PF0 配置应保持。
  // 失败/边界：失败若留下 active lease、VFE 或 NumVFs 则报告 UVM error。
  task automatic test_failure_rollback();
    rdma_pcie_bar_allocator tiny_allocator;
    rdma_sriov_enumerator failing_enumerator;
    rdma_status status;
    rdma_pcie_function_info discovered[$];

    tiny_allocator = rdma_pcie_bar_allocator::type_id::create("tiny_allocator");
    status = tiny_allocator.configure('{value:64'h0000_0002_0000_0000}, 64'h0000_0000_0000_8000);
    if (!status.ok()) `uvm_fatal("TINY_ALLOC", status.convert2string())
    failing_enumerator = rdma_sriov_enumerator::type_id::create("failing_enumerator");
    status = failing_enumerator.configure(pcie_adapter, tiny_allocator);
    if (!status.ok()) `uvm_fatal("FAIL_ENUM_CONFIG", status.convert2string())
    failing_enumerator.enumerate_and_configure_pf(
      '{segment:16'h0, bus:8'h1, device:5'h0, function_num:3'h0},
      2, discovered, status);
    if (status.ok() || tiny_allocator.active_lease_count() != 0 ||
        func_mgr.sriov_caps[0].vf_enable ||
        func_mgr.sriov_caps[0].num_vfs != 0)
      `uvm_error("ROLLBACK", "failed SR-IOV enumeration was not rolled back")
  endtask

  // 功能：创建一个独立的单 PF fault-injection fixture，确保每个失败场景从
  //   未启用 VF、无 active lease 的干净状态开始。
  // 输入/输出及副作用：tag（输入）、manager/adapter/allocator/enumerator（输出）；
  //   新建并配置 PCIe canonical 对象，不修改本测试的主 fixture。
  // 失败/边界：任一 configure 失败立即 fatal；返回的对象均由调用方持有，
  //   adapter/enumerator 不接管 manager/allocator 生命周期。
  task automatic build_fault_fixture(
    string tag,
    output pcie_tl_func_manager local_mgr,
    output rdma_sriov_fault_pcie_adapter local_adapter,
    output rdma_pcie_bar_allocator local_allocator,
    output rdma_sriov_enumerator local_enumerator
  );
    pcie_tl_bar_decoder local_decoder;
    rdma_status local_status;

    local_mgr = pcie_tl_func_manager::type_id::create({tag, "_mgr"});
    local_mgr.cfg_profile = PCIE_CFG_PROFILE_DPU_20F9_501X;
    local_mgr.build(1, 8);
    local_mgr.disable_vfs(0);
    local_mgr.sriov_caps[0].first_vf_offset = 16'h0005;
    local_mgr.sriov_caps[0].vf_stride = 16'h0003;
    local_mgr.sriov_caps[0].num_vfs = 0;
    local_mgr.sriov_caps[0].vf_enable = 1'b0;
    for (int vf = 0; vf < local_mgr.max_vfs_per_pf; vf++) begin
      local_mgr.vf_ctx[0][vf].bdf = local_mgr.sriov_caps[0].get_vf_rid(vf);
      local_mgr.vf_ctx[0][vf].enabled = 1'b0;
    end
    local_mgr.sync_sriov_cfg_image(0);

    local_decoder = pcie_tl_bar_decoder::type_id::create({tag, "_decoder"});
    local_adapter = rdma_sriov_fault_pcie_adapter::type_id::create(
      {tag, "_adapter"});
    local_status = local_adapter.configure(local_mgr, local_decoder,
                                            null, 1'b1);
    if (local_status == null || !local_status.ok())
      `uvm_fatal("FAULT_ADAPTER", local_status == null ? "null" :
                 local_status.convert2string())

    local_allocator = rdma_pcie_bar_allocator::type_id::create(
      {tag, "_allocator"});
    local_status = local_allocator.configure(
      '{value:64'h0000_0003_0000_0000}, 64'h0000_0010_0000_0000);
    if (local_status == null || !local_status.ok())
      `uvm_fatal("FAULT_ALLOCATOR", local_status == null ? "null" :
                 local_status.convert2string())
    local_enumerator = rdma_sriov_enumerator::type_id::create(
      {tag, "_enumerator"});
    local_status = local_enumerator.configure(local_adapter, local_allocator);
    if (local_status == null || !local_status.ok())
      `uvm_fatal("FAULT_ENUMERATOR", local_status == null ? "null" :
                 local_status.convert2string())
  endtask

  // 功能：运行一个故障注入场景并校验 enumerate_and_configure_pf 的原子回滚。
  // 输入/输出及副作用：tag/mode（输入）；驱动真实 config/BAR 流程，失败后检查
  //   VFE、VF-MSE、NumVFs 和 allocator active lease 均恢复为零。
  // 失败/边界：mode=0/1/2/3 分别覆盖 cfg write、BAR sizing read、VF config read
  //   和 decode_bar 失败；任何场景意外成功或残留资源都会报告 UVM error。
  task automatic run_failure_injection_case(string tag, int unsigned mode);
    pcie_tl_func_manager local_mgr;
    rdma_sriov_fault_pcie_adapter local_adapter;
    rdma_pcie_bar_allocator local_allocator;
    rdma_sriov_enumerator local_enumerator;
    rdma_pcie_function_info discovered[$];
    rdma_status status;
    rdma_bdf_t pf_bdf;

    build_fault_fixture(tag, local_mgr, local_adapter, local_allocator,
                        local_enumerator);
    case (mode)
      0: local_adapter.fail_cfg_write_at = 1;
      1: local_adapter.fail_cfg_read_at = 2;
      2: local_adapter.fail_vf_vendor_read = 1'b1;
      3: local_adapter.fail_decode_bar_once = 1'b1;
      default: `uvm_fatal("FAULT_MODE", "unknown SR-IOV fault mode")
    endcase
    pf_bdf = '{segment:16'h0, bus:8'h1, device:5'h0, function_num:3'h0};
    local_enumerator.enumerate_and_configure_pf(
      pf_bdf, 2, discovered, status);
    if (status == null || status.ok())
      `uvm_error("FAULT_EXPECTED", $sformatf(
        "%s unexpectedly completed SR-IOV enumeration", tag))
    if (local_allocator.active_lease_count() != 0 ||
        local_mgr.sriov_caps[0].vf_enable ||
        local_mgr.sriov_caps[0].vf_mse ||
        local_mgr.sriov_caps[0].num_vfs != 0)
      `uvm_error("FAULT_ROLLBACK", $sformatf(
        "%s left leases or SR-IOV state after failure", tag))
  endtask

  // 功能：覆盖配置写失败、BAR sizing 读失败、VF 配置读失败和 BAR decoder
  //   失败四类主要异常，并确认每类都执行完整回滚。
  // 输入/输出及副作用：无显式参数；依次运行四个独立 fixture，保留每个场景
  //   的首个错误状态供 UVM 汇总。
  // 失败/边界：任一场景的 rollback 断言失败由 run_failure_injection_case 报告。
  task automatic test_failure_injection_rollback();
    run_failure_injection_case("cfg_write_failure", 0);
    run_failure_injection_case("bar_sizing_read_failure", 1);
    run_failure_injection_case("vf_config_read_failure", 2);
    run_failure_injection_case("bar_decode_failure", 3);
  endtask

  // 功能：运行双 PF 枚举和失败回滚测试，并按 UVM 约定管理 objection。
  // 输入/输出及副作用：phase（输入）；执行所有测试任务，完成后 drop_objection。
  // 失败/边界：任何测试任务都不得吞掉 status；UVM error/fatal 由测试框架汇总。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    test_failure_injection_rollback();
    build_fixture();
    test_two_pf_enumeration();
    test_failure_rollback();
    phase.drop_objection(this);
  endtask
endclass
