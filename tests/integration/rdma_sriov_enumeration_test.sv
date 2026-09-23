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
//   manager/adapter，避免残留计数或配置状态串到下一用例；VF vendor 计数只统计
//   offset=0 的 VF 读取，不能把 PF/BAR 访问误算为第二个 VF。
class rdma_sriov_fault_pcie_adapter extends rdma_pcie_work_adapter;
  `uvm_object_utils(rdma_sriov_fault_pcie_adapter)

  bit fail_vf_vendor_read;
  bit fail_decode_bar_once;
  bit null_get_function_info;
  bit null_discover_sriov;
  bit null_cfg_read;
  bit null_cfg_write;
  bit null_decode_bar;
  int fail_cfg_read_at;
  int fail_cfg_write_at;
  int fail_vf_vendor_read_at;
  int cfg_read_count;
  int cfg_write_count;
  int vf_vendor_read_count;

  // 功能：构造故障注入 adapter 并清零计数器。
  // 输入/输出及副作用：name（输入）；仅初始化本地 fault 控制字段。
  // 失败/边界：构造成功不代表后端已 configure，所有业务入口仍沿用基类检查。
  function new(string name = "rdma_sriov_fault_pcie_adapter");
    super.new(name);
    fail_vf_vendor_read = 1'b0;
    fail_decode_bar_once = 1'b0;
    null_get_function_info = 1'b0;
    null_discover_sriov = 1'b0;
    null_cfg_read = 1'b0;
    null_cfg_write = 1'b0;
    null_decode_bar = 1'b0;
    fail_cfg_read_at = 0;
    fail_cfg_write_at = 0;
    fail_vf_vendor_read_at = 0;
    cfg_read_count = 0;
    cfg_write_count = 0;
    vf_vendor_read_count = 0;
  endfunction

  // 功能：在指定 cfg read 调用上注入 PCIE completion 或 null-status 故障，覆盖
  //   BAR sizing、VF Vendor/Device 读取和后端违约路径。
  // 输入/输出及副作用：target/offset（输入）、data/status（输出）；注入时不修改
  //   config image，否则调用基类实现完成真实读取；offset=0 的调用递增 VF vendor
  //   序号，供第二 VF 的原子回滚场景精确定位。
  // 失败/边界：null_cfg_read 优先返回 null status；fail_cfg_read_at 从 1 开始计数；
  //   fail_vf_vendor_read 拒绝所有 offset=0 的 VF 读取，fail_vf_vendor_read_at 仅
  //   拒绝指定序号；注入时 data 保持全 1，模拟 Unsupported Request。
  virtual task cfg_read32(
    rdma_bdf_t target,
    rdma_cfg_offset_t offset,
    output bit [31:0] data,
    output rdma_status status
  );
    pcie_tl_func_context target_ctx;

    if (null_cfg_read) begin
      data = 32'hffff_ffff;
      status = null;
      return;
    end
    cfg_read_count++;
    target_ctx = (func_mgr == null) ? null :
                 func_mgr.lookup_by_bdf(raw_bdf(target));
    if (offset.value == 12'h000 && target_ctx != null && target_ctx.is_vf)
      vf_vendor_read_count++;
    if ((fail_cfg_read_at > 0 && cfg_read_count == fail_cfg_read_at) ||
        (fail_vf_vendor_read && offset.value == 12'h000 &&
         target_ctx != null && target_ctx.is_vf) ||
        (fail_vf_vendor_read_at > 0 && offset.value == 12'h000 &&
         target_ctx != null && target_ctx.is_vf &&
         vf_vendor_read_count == fail_vf_vendor_read_at)) begin
      data = 32'hffff_ffff;
      status = rdma_status::make(RDMA_SC_PCIE_COMPLETION,
                                 "injected PCIe config read failure");
      status.source_engine = RDMA_ENGINE_PCIE;
      return;
    end
    super.cfg_read32(target, offset, data, status);
  endtask

  // 功能：在指定 cfg write 调用上注入 PCIE completion 或 null-status 故障，验证
  //   枚举器在 BAR/NumVFs/Control 编程任一阶段都能回滚。
  // 输入/输出及副作用：target/offset/data/byte_enable（输入）、status（输出）；
  //   注入时不更新 manager 或配置代理，否则调用基类提交真实写入。
  // 失败/边界：null_cfg_write 优先返回 null status；fail_cfg_write_at 从 1 开始
  //   计数，零表示不按序号注入；注入时不修改 config image。
  virtual task cfg_write32(
    rdma_bdf_t target,
    rdma_cfg_offset_t offset,
    bit [31:0] data,
    bit [3:0] byte_enable,
    output rdma_status status
  );
    if (null_cfg_write) begin
      status = null;
      return;
    end
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
    if (null_decode_bar) begin
      result = null;
      return null;
    end
    if (fail_decode_bar_once) begin
      fail_decode_bar_once = 1'b0;
      result = null;
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "injected BAR decoder failure");
    end
    return super.decode_bar(address, result);
  endfunction

  // 功能：在 Function snapshot 查询边界注入 null status，验证枚举器不解引用空值。
  // 输入/输出及副作用：bdf（输入）、info（输出）；故障时清空 info 并返回 null，正常时转发基类。
  // 失败/边界：null_get_function_info 只模拟 backend 违约，不代表一个合法的 PCIe completion。
  virtual function rdma_status get_function_info(
    rdma_bdf_t bdf,
    output rdma_pcie_function_info info
  );
    if (null_get_function_info) begin
      info = null;
      return null;
    end
    return super.get_function_info(bdf, info);
  endfunction

  // 功能：在 SR-IOV capability 查询边界注入 null status，验证枚举器不消费零值 capability。
  // 输入/输出及副作用：pf_bdf（输入）、info（输出）；故障时清零 info 并返回 null，正常时转发基类。
  // 失败/边界：null_discover_sriov 仅用于 hostile adapter 测试，调用方必须转换为 INVALID_STATE。
  virtual function rdma_status discover_sriov(
    rdma_bdf_t pf_bdf,
    output rdma_pcie_sriov_info info
  );
    if (null_discover_sriov) begin
      info = '{default:'0};
      return null;
    end
    return super.discover_sriov(pf_bdf, info);
  endfunction

endclass

class rdma_sriov_enumeration_test extends uvm_test;
  `uvm_component_utils(rdma_sriov_enumeration_test)

  pcie_tl_func_manager func_mgr;
  pcie_tl_bar_decoder bar_decoder;
  pcie_tl_config_proxy config_proxy;
  // 故障夹具在 run_phase task 中建立，因此 config proxy 必须预先属于 UVM 层级。
  // 该 proxy 只在串行 fixture 之间复用；任一时刻不会有两个故障 adapter 同时使用它，
  // 每次交接都会在下方重新绑定 canonical manager。
  pcie_tl_config_proxy fault_config_proxy;
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
    fault_config_proxy = pcie_tl_config_proxy::type_id::create(
      "fault_config_proxy", this);
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
  // 输入/输出及副作用：创建独立 manager/adapter/allocator/sequence fixture 并执行一次
  //   失败枚举；主 fixture 已成功启用的 PF0/PF1 不参与本场景，避免把既有 ownership
  //   误当成待回滚状态。
  // 失败/边界：失败若留下 active lease、VFE 或 NumVFs 则报告 UVM error；入口 PF
  //   若已有 SR-IOV ownership，本场景应先 fail-closed，而不是伪造回滚成功。
  task automatic test_failure_rollback();
    pcie_tl_func_manager rollback_mgr;
    rdma_sriov_fault_pcie_adapter rollback_adapter;
    rdma_pcie_bar_allocator rollback_fixture_allocator;
    rdma_sriov_enumerator rollback_enumerator;
    rdma_pcie_bar_allocator tiny_allocator;
    rdma_sriov_enumerator failing_enumerator;
    rdma_status status;
    rdma_pcie_function_info discovered[$];

    build_fault_fixture("tiny_rollback", rollback_mgr, rollback_adapter,
                        rollback_fixture_allocator, rollback_enumerator);
    tiny_allocator = rdma_pcie_bar_allocator::type_id::create("tiny_allocator");
    status = tiny_allocator.configure('{value:64'h0000_0002_0000_0000}, 64'h0000_0000_0000_8000);
    if (!status.ok()) `uvm_fatal("TINY_ALLOC", status.convert2string())
    failing_enumerator = rdma_sriov_enumerator::type_id::create("failing_enumerator");
    status = failing_enumerator.configure(rollback_adapter, tiny_allocator);
    if (!status.ok()) `uvm_fatal("FAIL_ENUM_CONFIG", status.convert2string())
    failing_enumerator.enumerate_and_configure_pf(
      '{segment:16'h0, bus:8'h1, device:5'h0, function_num:3'h0},
      2, discovered, status);
    if (status.ok() || tiny_allocator.active_lease_count() != 0 ||
        rollback_mgr.sriov_caps[0].vf_enable ||
        rollback_mgr.sriov_caps[0].num_vfs != 0)
      `uvm_error("ROLLBACK", "failed SR-IOV enumeration was not rolled back")
  endtask

  // 功能：创建一个独立的单 PF fault-injection fixture，确保每个失败场景从
  //   未启用 VF、无 active lease 的干净状态开始。
  // 输入/输出及副作用：tag（输入）、manager/adapter/allocator/enumerator（输出）；
  //   新建并配置 PCIe canonical 对象；config proxy 复用 build_phase 所有的
  //   fault_config_proxy，不修改本测试的主 fixture。
  // 失败/边界：任一 configure 失败立即 fatal；返回的对象均由调用方持有，
  //   adapter/enumerator 不接管 manager/allocator 生命周期；复用 proxy 的
  //   manager 引用只在本 task 完成前有效，调用方必须串行使用返回的 adapter。
  task automatic build_fault_fixture(
    string tag,
    output pcie_tl_func_manager local_mgr,
    output rdma_sriov_fault_pcie_adapter local_adapter,
    output rdma_pcie_bar_allocator local_allocator,
    output rdma_sriov_enumerator local_enumerator
  );
    pcie_tl_bar_decoder local_decoder;
    pcie_tl_config_proxy local_proxy;
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
    // 该 helper 在 build_phase 之后运行，复用 build_phase 创建的 test child，
    // 不再向已结束的 UVM 构建阶段插入 component。
    if (fault_config_proxy == null)
      `uvm_fatal("FAULT_PROXY", "fault config proxy was not built")
    local_proxy = fault_config_proxy;
    local_proxy.func_mgr = local_mgr;
    local_proxy.multi_function_mode = 1'b1;
    local_proxy.bar0_sizing_lo = 1'b0;
    local_proxy.bar0_sizing_hi = 1'b0;
    local_proxy.bar0_addr = '0;
    local_proxy.init_config_space();
    local_adapter = rdma_sriov_fault_pcie_adapter::type_id::create(
      {tag, "_adapter"});
    // 故障夹具必须保留真实 config-proxy 路径；model-bypass 只返回原始
    // descriptor flags，无法模拟 BAR sizing write/read 往返，导致 vendor
    // fault 之前就被错误的 aperture 拒绝。proxy 的 manager 引用由该对象
    // 持有，adapter 只借用它，生命周期覆盖整个本次 task。
    local_status = local_adapter.configure(local_mgr, local_decoder,
                                            local_proxy, 1'b0);
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

  // 功能：运行一个故障注入场景并校验 enumerate_and_configure_pf 的原子回滚，
  //   同时确认 PF/VF 64-bit BAR 的 low/high canonical base 与 sizing 状态回到入口快照。
  // 输入/输出及副作用：tag/mode（输入）；先在独立 fixture 中建立非零 PF/VF BAR
  //   基线，再驱动真实 config/BAR 流程；失败后观察 VFE、VF-MSE、NumVFs、lease
  //   账本及 BAR 配置，不转移 fixture 所有权。
  // 失败/边界：mode=0/1/2/3 分别覆盖 cfg write、BAR sizing read、VF0 config read
  //   和 decode_bar 失败，mode=4 只拒绝第二个 VF 的 vendor read；mode=4 还必须
  //   观察到 vendor_read_count=2。任一 base、sizing、discovered 或资源字段漂移、
  //   意外成功均报告 UVM error。
  task automatic run_failure_injection_case(string tag, int unsigned mode);
    pcie_tl_func_manager local_mgr;
    rdma_sriov_fault_pcie_adapter local_adapter;
    rdma_pcie_bar_allocator local_allocator;
    rdma_sriov_enumerator local_enumerator;
    rdma_pcie_function_info discovered[$];
    rdma_pcie_function_info sentinel;
    rdma_status status;
    rdma_bdf_t pf_bdf;
    bit [63:0] original_pf_base[6];
    bit [63:0] original_vf_base[6];
    bit original_pf_sizing[6];
    bit original_vf_sizing[6];

    build_fault_fixture(tag, local_mgr, local_adapter, local_allocator,
                        local_enumerator);
    // mode 0..3 使用非零且 4-KiB 对齐的基线暴露 low/high DWORD 遗留；高 DWORD
    // 由 canonical 64-bit base 隐含保存，sizing 位则覆盖“只写 sizing mask”失败。
    // mode 4 必须走完整 VF0/VF1 路径，保留 profile 原生 descriptor，避免测试注入
    // 的非默认 base 先制造与 VF vendor fault 无关的 sizing 失败。
    if (mode != 4) begin
      local_mgr.pf_ctx[0].bar_base[0] = 64'h0000_0001_1000_0000;
      local_mgr.sriov_caps[0].vf_bar[0] = 64'h0000_0002_2000_0000;
    end
    foreach (original_pf_base[i]) begin
      original_pf_base[i] = local_mgr.pf_ctx[0].bar_base[i];
      original_vf_base[i] = local_mgr.sriov_caps[0].vf_bar[i];
      original_pf_sizing[i] = local_mgr.pf_ctx[0].bar_sizing[i];
      original_vf_sizing[i] = local_mgr.sriov_caps[0].vf_bar_sizing[i];
    end
    case (mode)
      0: local_adapter.fail_cfg_write_at = 1;
      1: local_adapter.fail_cfg_read_at = 2;
      2: local_adapter.fail_vf_vendor_read = 1'b1;
      3: local_adapter.fail_decode_bar_once = 1'b1;
      4: begin
        local_adapter.fail_vf_vendor_read_at = 2;
        sentinel = rdma_pcie_function_info::type_id::create(
          {tag, "_sentinel"});
        discovered.push_back(sentinel);
      end
      default: `uvm_fatal("FAULT_MODE", "unknown SR-IOV fault mode")
    endcase
    pf_bdf = '{segment:16'h0, bus:8'h1, device:5'h0, function_num:3'h0};
    local_enumerator.enumerate_and_configure_pf(
      pf_bdf, 2, discovered, status);
    if (status == null || status.ok())
      `uvm_error("FAULT_EXPECTED", $sformatf(
        "%s unexpectedly completed SR-IOV enumeration", tag))
    if (mode == 4 && local_adapter.vf_vendor_read_count != 2)
      `uvm_error("FAULT_VF_INDEX", $sformatf(
        "%s did not reach the second VF vendor read (count=%0d status=%s)",
        tag, local_adapter.vf_vendor_read_count,
        status == null ? "null" : status.convert2string()))
    if (discovered.size() != 0)
      `uvm_error("FAULT_DISCOVERED_ATOMIC", $sformatf(
        "%s published partial Function snapshots after failure", tag))
    if (local_allocator.active_lease_count() != 0 ||
        local_mgr.sriov_caps[0].vf_enable ||
        local_mgr.sriov_caps[0].vf_mse ||
        local_mgr.sriov_caps[0].num_vfs != 0)
      `uvm_error("FAULT_ROLLBACK", $sformatf(
        "%s left leases or SR-IOV state after failure", tag))
    foreach (original_pf_base[i]) begin
      if (local_mgr.pf_ctx[0].bar_base[i] != original_pf_base[i] ||
          local_mgr.pf_ctx[0].bar_sizing[i] != original_pf_sizing[i])
        `uvm_error("PF_BAR_ROLLBACK", $sformatf(
          "%s changed PF BAR%0d base/sizing during rollback", tag, i))
      if (local_mgr.sriov_caps[0].vf_bar[i] != original_vf_base[i] ||
          local_mgr.sriov_caps[0].vf_bar_sizing[i] != original_vf_sizing[i])
        `uvm_error("VF_BAR_ROLLBACK", $sformatf(
          "%s changed VF BAR%0d base/sizing during rollback", tag, i))
    end
  endtask

  // 功能：覆盖配置写失败、BAR sizing 读失败、VF0/VF1 配置读失败和 BAR decoder
  //   失败五类主要异常，并确认每类都执行完整回滚。
  // 输入/输出及副作用：无显式参数；依次运行五个独立 fixture，保留每个场景
  //   的首个错误状态供 UVM 汇总。
  // 失败/边界：任一场景的 rollback 断言失败由 run_failure_injection_case 报告。
  task automatic test_failure_injection_rollback();
    run_failure_injection_case("cfg_write_failure", 0);
    run_failure_injection_case("bar_sizing_read_failure", 1);
    run_failure_injection_case("vf_config_read_failure", 2);
    run_failure_injection_case("bar_decode_failure", 3);
    run_failure_injection_case("vf1_vendor_read_failure", 4);
  endtask

  // 功能：验证 PCIe backend 在 get/discover/cfg/decode 任一边界返回 null status 时，
  //   枚举器均发布非空 INVALID_STATE 并释放已取得的 lease。
  // 输入/输出及副作用：为每个故障建立独立 fixture，调用 enumerate_and_configure_pf；
  //   只观察 status、discovered 和 allocator/PF 回滚状态。
  // 失败/边界：若出现 null status、UVM fatal、意外成功或残留 lease/VFE，测试报告错误。
  task automatic test_null_status_fail_closed();
    pcie_tl_func_manager local_mgr;
    rdma_sriov_fault_pcie_adapter local_adapter;
    rdma_pcie_bar_allocator local_allocator;
    rdma_sriov_enumerator local_enumerator;
    rdma_pcie_function_info discovered[$];
    rdma_status status;
    rdma_bdf_t pf_bdf;

    pf_bdf = '{segment:16'h0, bus:8'h1, device:5'h0, function_num:3'h0};

    build_fault_fixture("null_get_info", local_mgr, local_adapter,
                        local_allocator, local_enumerator);
    local_adapter.null_get_function_info = 1'b1;
    local_enumerator.enumerate_and_configure_pf(
      pf_bdf, 2, discovered, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        local_allocator.active_lease_count() != 0)
      `uvm_error("NULL_GET_INFO", "null Function status was not fail-closed")

    build_fault_fixture("null_discover", local_mgr, local_adapter,
                        local_allocator, local_enumerator);
    local_adapter.null_discover_sriov = 1'b1;
    local_enumerator.enumerate_and_configure_pf(
      pf_bdf, 2, discovered, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        local_allocator.active_lease_count() != 0)
      `uvm_error("NULL_DISCOVER", "null SR-IOV status was not fail-closed")

    build_fault_fixture("null_cfg_read", local_mgr, local_adapter,
                        local_allocator, local_enumerator);
    local_adapter.null_cfg_read = 1'b1;
    local_enumerator.enumerate_and_configure_pf(
      pf_bdf, 2, discovered, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        local_allocator.active_lease_count() != 0 ||
        local_mgr.sriov_caps[0].vf_enable ||
        local_mgr.sriov_caps[0].num_vfs != 0)
      `uvm_error("NULL_CFG_READ", "null cfg-read status was not fail-closed")

    build_fault_fixture("null_cfg_write", local_mgr, local_adapter,
                        local_allocator, local_enumerator);
    local_adapter.null_cfg_write = 1'b1;
    local_enumerator.enumerate_and_configure_pf(
      pf_bdf, 2, discovered, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        local_allocator.active_lease_count() != 0 ||
        local_mgr.sriov_caps[0].vf_enable ||
        local_mgr.sriov_caps[0].num_vfs != 0)
      `uvm_error("NULL_CFG_WRITE", "null cfg-write status was not fail-closed")

    build_fault_fixture("null_decode", local_mgr, local_adapter,
                        local_allocator, local_enumerator);
    local_adapter.null_decode_bar = 1'b1;
    local_enumerator.enumerate_and_configure_pf(
      pf_bdf, 2, discovered, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        local_allocator.active_lease_count() != 0 ||
        local_mgr.sriov_caps[0].vf_enable ||
        local_mgr.sriov_caps[0].num_vfs != 0)
      `uvm_error("NULL_DECODE", "null BAR decode status was not fail-closed")
  endtask

  // 功能：验证 PF 已存在 SR-IOV ownership 时，enumerator 在 discover_sriov
  //   之后立即拒绝接管，并保留入口时的启用状态和 BAR 配置。
  // 输入/输出及副作用：tag/num_vfs/vf_enable/vf_mse（输入）；为每个场景创建
  //   独立 manager/adapter/allocator/enumerator，执行一次枚举并比较 PF/VF BAR、
  //   SR-IOV 状态和 allocator lease 的入口快照，不修改外部 PCIe 源码。
  // 失败/边界：任一已启用字段必须触发 INVALID_STATE；拒绝路径不得留下 lease、
  //   discovered Function、BAR base/sizing 漂移，也不得把已有配置清零或改写。
  task automatic run_preexisting_sriov_case(
    string tag,
    bit [15:0] existing_num_vfs,
    bit existing_vf_enable,
    bit existing_vf_mse
  );
    pcie_tl_func_manager local_mgr;
    rdma_sriov_fault_pcie_adapter local_adapter;
    rdma_pcie_bar_allocator local_allocator;
    rdma_sriov_enumerator local_enumerator;
    rdma_pcie_function_info discovered[$];
    rdma_status status;
    rdma_bdf_t pf_bdf;
    bit [63:0] original_pf_base[6];
    bit [63:0] original_vf_base[6];
    bit original_pf_sizing[6];
    bit original_vf_sizing[6];
    bit [15:0] original_num_vfs;
    bit original_vf_enable;
    bit original_vf_mse;

    build_fault_fixture(tag, local_mgr, local_adapter, local_allocator,
                        local_enumerator);

    // 非零、对齐的地址让 guard 之后的“未写 BAR”契约可被直接观察；这些
    //   canonical 字段由 manager 所有，enumerator 只能通过 cfg API 间接访问。
    local_mgr.pf_ctx[0].bar_base[0] = 64'h0000_0001_3100_0000;
    local_mgr.sriov_caps[0].vf_bar[0] = 64'h0000_0002_4200_0000;
    if (existing_num_vfs != 0 && existing_vf_enable) begin
      // 这一支使用 canonical manager 的 enable_vfs() 真正建立 VF LUT，
      //   证明 guard 保护的是外部已拥有的 PF，而不是测试夹具中的孤立位。
      local_mgr.enable_vfs(0, int'(existing_num_vfs));
    end
    else begin
      local_mgr.sriov_caps[0].num_vfs = existing_num_vfs;
      local_mgr.sriov_caps[0].vf_enable = existing_vf_enable;
    end
    local_mgr.sriov_caps[0].vf_mse = existing_vf_mse;
    local_mgr.sync_sriov_cfg_image(0);

    foreach (original_pf_base[i]) begin
      original_pf_base[i] = local_mgr.pf_ctx[0].bar_base[i];
      original_vf_base[i] = local_mgr.sriov_caps[0].vf_bar[i];
      original_pf_sizing[i] = local_mgr.pf_ctx[0].bar_sizing[i];
      original_vf_sizing[i] = local_mgr.sriov_caps[0].vf_bar_sizing[i];
    end
    original_num_vfs = local_mgr.sriov_caps[0].num_vfs;
    original_vf_enable = local_mgr.sriov_caps[0].vf_enable;
    original_vf_mse = local_mgr.sriov_caps[0].vf_mse;

    pf_bdf = '{segment:16'h0, bus:8'h1, device:5'h0, function_num:3'h0};
    local_enumerator.enumerate_and_configure_pf(
      pf_bdf, 2, discovered, status);

    if (status == null || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("PREEXISTING_STATE", $sformatf(
        "%s did not reject pre-existing SR-IOV state: %s", tag,
        status == null ? "null" : status.convert2string()))
    if (discovered.size() != 0 || local_allocator.active_lease_count() != 0)
      `uvm_error("PREEXISTING_RESOURCES", $sformatf(
        "%s published Function snapshots or leases before rejection", tag))
    if (local_mgr.sriov_caps[0].num_vfs != original_num_vfs ||
        local_mgr.sriov_caps[0].vf_enable != original_vf_enable ||
        local_mgr.sriov_caps[0].vf_mse != original_vf_mse)
      `uvm_error("PREEXISTING_STATE_MUTATION", $sformatf(
        "%s changed pre-existing SR-IOV Control/NumVFs state", tag))
    foreach (original_pf_base[i]) begin
      if (local_mgr.pf_ctx[0].bar_base[i] != original_pf_base[i] ||
          local_mgr.pf_ctx[0].bar_sizing[i] != original_pf_sizing[i])
        `uvm_error("PREEXISTING_PF_BAR", $sformatf(
          "%s changed PF BAR%0d while rejecting pre-existing state", tag, i))
      if (local_mgr.sriov_caps[0].vf_bar[i] != original_vf_base[i] ||
          local_mgr.sriov_caps[0].vf_bar_sizing[i] != original_vf_sizing[i])
        `uvm_error("PREEXISTING_VF_BAR", $sformatf(
          "%s changed VF BAR%0d while rejecting pre-existing state", tag, i))
    end
  endtask

  // 功能：覆盖 NumVFs、VFE 和 VF-MSE 三种既有 ownership 标志，确认每个
  //   fail-closed 条件都独立生效；额外的 NumVFs+VFE 组合使用真实 enable_vfs
  //   路径，确保 canonical VF LUT 也属于被保护的既有状态。
  // 输入/输出及副作用：无显式参数；每个子场景使用全新 fixture，结果由
  //   run_preexisting_sriov_case 统一报告，避免前一场景的状态泄漏。
  // 失败/边界：任一子场景允许枚举继续、清零入口状态或残留资源都会产生 UVM error。
  task automatic test_preexisting_sriov_rejected();
    run_preexisting_sriov_case("preexisting_num_vfs", 16'd2, 1'b0, 1'b0);
    run_preexisting_sriov_case("preexisting_num_vfs_vfe", 16'd2, 1'b1, 1'b0);
    run_preexisting_sriov_case("preexisting_vf_enable", 16'd0, 1'b1, 1'b0);
    run_preexisting_sriov_case("preexisting_vf_mse", 16'd0, 1'b0, 1'b1);
  endtask

  // 功能：验证 VF BAR owner 编码超出 0..5 时，enumerator 立即拒绝而不把
  //       当前索引当作隐式 owner。
  // 输入/输出及副作用：创建独立 PCIe/allocator fixture，篡改 canonical
  //       vf_bar_owner[0] 后执行一次 PF 枚举并观察 status、discovered 与 lease。
  // 失败/边界：非法 owner 必须返回 INVALID_ARGUMENT/INVALID_STATE，且不得
  //       写入 VFE/NumVFs 或留下 allocator lease；合法 owner 的既有路径不变。
  task automatic test_invalid_vf_bar_owner_rejected();
    pcie_tl_func_manager local_mgr;
    rdma_sriov_fault_pcie_adapter local_adapter;
    rdma_pcie_bar_allocator local_allocator;
    rdma_sriov_enumerator local_enumerator;
    rdma_pcie_function_info discovered[$];
    rdma_status status;
    rdma_bdf_t pf_bdf;

    build_fault_fixture("invalid_vf_bar_owner", local_mgr, local_adapter,
                        local_allocator, local_enumerator);
    local_mgr.sriov_caps[0].vf_bar_owner[0] = 3'b111;
    local_mgr.sync_sriov_cfg_image(0);
    pf_bdf = '{segment:16'h0, bus:8'h1, device:5'h0, function_num:3'h0};
    local_enumerator.enumerate_and_configure_pf(
      pf_bdf, 2, discovered, status);
    if (status == null ||
        !(status.code inside {RDMA_SC_INVALID_ARGUMENT,
                              RDMA_SC_INVALID_STATE}) ||
        discovered.size() != 0 ||
        local_allocator.active_lease_count() != 0 ||
        local_mgr.sriov_caps[0].vf_enable ||
        local_mgr.sriov_caps[0].num_vfs != 0)
      `uvm_error("INVALID_VF_BAR_OWNER",
                 "invalid vf_bar_owner was silently mapped to the loop index")
  endtask

  // 功能：运行双 PF 枚举和失败回滚测试，并按 UVM 约定管理 objection。
  // 输入/输出及副作用：phase（输入）；执行所有测试任务，完成后 drop_objection。
  // 失败/边界：任何测试任务都不得吞掉 status；UVM error/fatal 由测试框架汇总。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    test_null_status_fail_closed();
    test_preexisting_sriov_rejected();
    test_invalid_vf_bar_owner_rejected();
    test_failure_injection_rollback();
    build_fixture();
    test_two_pf_enumeration();
    test_failure_rollback();
    phase.drop_objection(this);
  endtask
endclass
