// 目录/层次：tests/integration/ 集成测试层，验证 pcie_work adapter 的 Function-aware 配置和 BAR 路由。
// 职责：用外部 pcie_tl_func_manager 构造 PF/VF/SR-IOV 拓扑，检查配置读写、
//   VF BAR 解码、MMIO authority 和 stale generation 拒绝边界。
// 依赖：pcie_tl_pkg、rdma_pcie_work_adapter_pkg、rdma_model_pkg、UVM；测试不拥有
//   pcie_tl manager 之外的外部环境，adapter 只保存这些对象的非拥有引用。
// 所有权与生命周期：测试只拥有本地 adapter/configuration fixture；pcie_tl manager、BAR
//       decoder 和配置代理由外部环境管理，测试结束时释放本地 UVM 引用。

class rdma_pcie_work_adapter_test extends uvm_test;
  `uvm_component_utils(rdma_pcie_work_adapter_test)

  pcie_tl_func_manager func_mgr;
  pcie_tl_bar_decoder bar_decoder;
  pcie_tl_config_proxy config_proxy;
  rdma_pcie_work_adapter adapter;

  // 功能：构造 PCIe adapter 集成测试组件，建立 UVM 层级关系但不创建外部 PCIe 环境。
  // 输入/输出及副作用：name、parent（输入）；new 仅调用 super.new，不分配 PF/VF、BAR
  //   或 MMIO 资源；对象和 component fixture 在 build_phase 中创建并由 UVM 层级管理。
  // 失败/边界：构造不会掩盖后端句柄缺失；若 run_phase 未完成 configure，所有 adapter
  //   入口都必须按 INVALID_STATE 返回，而不能伪造 PCIe 成功。
  function new(string name = "rdma_pcie_work_adapter_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 UVM build 阶段创建测试所需的 PCIe manager、BAR decoder、配置代理和
  //   RDMA adapter，确保 component 类型的 config_proxy 遵守 UVM 生命周期约束。
  // 输入/输出及副作用：phase（输入）；建立本测试独占的对象层级并把 config_proxy 的
  //   manager 引用预先绑定，子组件随后可在自己的 build_phase 初始化配置空间。
  // 失败/边界：仅创建对象不代表拓扑已完成；若 build_fixture() 未成功配置 adapter，
  //   run_phase 中的业务入口仍必须按 INVALID_STATE 失败，不能因对象已存在而放行事务。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    func_mgr = pcie_tl_func_manager::type_id::create("func_mgr");
    func_mgr.cfg_profile = PCIE_CFG_PROFILE_DPU_20F9_501X;
    bar_decoder = pcie_tl_bar_decoder::type_id::create("bar_decoder");
    config_proxy = pcie_tl_config_proxy::type_id::create("config_proxy", this);
    config_proxy.func_mgr = func_mgr;
    config_proxy.multi_function_mode = 1'b1;
    adapter = rdma_pcie_work_adapter::type_id::create("adapter");
  endfunction

  // 功能：把 pcie_work 的 16 位 requester ID 投影为 RDMA 的 segment/bus/device/function
  //   快照，供 adapter API 使用同一条 Function 路由。
  // 输入/输出及副作用：raw_bdf（输入）；返回 detached rdma_bdf_t，不修改 manager 或 LUT。
  // 失败/边界：仅支持标准 3-bit function 表示；调用方必须在 ARI 扩展 function 超出该
  //   表示范围时拒绝绑定，避免静默截断身份。
  function automatic rdma_bdf_t to_rdma_bdf(bit [15:0] raw_bdf);
    rdma_bdf_t result;
    result.segment = 16'h0;
    result.bus = raw_bdf[15:8];
    result.device = raw_bdf[7:3];
    result.function_num = raw_bdf[2:0];
    return result;
  endfunction

  // 功能：在 DPU 20F9 profile 下建立一 PF、两 VF 的 manager/decoder/proxy fixture，
  //   并把 proxy 的 multi-function 路径连接到同一个 canonical manager。
  // 输入/输出及副作用：无显式参数；更新测试成员并调用 adapter.configure；成功时返回
  //   可用于配置读写和地址路由的本地 fixture，不接管外部对象所有权。
  // 失败/边界：任一对象创建或 configure 失败都通过 UVM fatal 暴露；fixture 不允许用
  //   影子表替代 func_mgr 的 BDF/LUT/SR-IOV 状态。
  task automatic build_fixture();
    rdma_status status;

    func_mgr.build(1, 16);
    func_mgr.enable_vfs(0, 2);
    func_mgr.sriov_caps[0].vf_mse = 1'b1;
    func_mgr.sync_sriov_cfg_image(0);
    func_mgr.pf_ctx[0].bar_base[0] = 64'h0000_0000_0200_0000;
    func_mgr.pf_ctx[0].bar_enable[0] = 1'b1;
    func_mgr.sriov_caps[0].vf_bar[0] = 64'h0000_0001_0000_0000;
    func_mgr.mark_routing_dirty("adapter test BAR fixture");

    bar_decoder.func_mgr = func_mgr;
    config_proxy.func_mgr = func_mgr;
    config_proxy.multi_function_mode = 1'b1;
    status = adapter.configure(func_mgr, bar_decoder, config_proxy, 1'b1);
    if (!status.ok())
      `uvm_fatal("PCIE_FIXTURE", status.convert2string())
  endtask

  // 功能：验证 SR-IOV capability、VF Function snapshot 和配置空间中的 MSE/BME 状态均
  //   来自 pcie_work canonical manager，并可注册给后续 MMIO authority 检查。
  // 输入/输出及副作用：读取 PF/VF BDF 并写入 command register；成功时更新 manager 的
  //   canonical command state和 adapter 的 Function route registry。
  // 失败/边界：未知 BDF、未对齐 offset 或 command 写入失败必须返回明确错误；不得从默认
  //   profile 猜测 VF BDF、BAR 或 MSE/BME。
  task automatic test_config_and_sriov();
    rdma_pcie_sriov_info sriov_info;
    rdma_pcie_function_info info;
    rdma_bdf_t pf_bdf;
    rdma_bdf_t vf_bdf;
    rdma_status status;
    bit [31:0] data;

    pf_bdf = to_rdma_bdf(func_mgr.pf_ctx[0].bdf);
    status = adapter.discover_sriov(pf_bdf, sriov_info);
    if (!status.ok() || sriov_info.first_vf_offset == 0 ||
        sriov_info.vf_stride == 0 || sriov_info.total_vfs < 2)
      `uvm_error("SRIOV", "capability was not discovered from manager")

    vf_bdf = to_rdma_bdf(func_mgr.vf_ctx[0][0].bdf);
    status = adapter.get_function_info(vf_bdf, info);
    if (!status.ok() || info.bar[0].size != 64'd16_384)
      `uvm_error("VF_INFO", "VF identity/BAR/command snapshot is incomplete")

    // VF 的 Command 默认由 manager 初始化为 0；通过 adapter 配置路径打开
    // Memory Space/Bus Master 后，再检查快照是否反映 canonical command image。
    adapter.cfg_write32(vf_bdf, '{value:12'h004},
                        32'h0000_0007, 4'hf, status);
    if (!status.ok())
      `uvm_error("VF_COMMAND_WRITE", "VF command write was rejected")
    status = adapter.get_function_info(vf_bdf, info);
    if (!status.ok() || !info.mse || !info.bme)
      `uvm_error("VF_COMMAND", "VF MSE/BME state did not follow config write")

    adapter.register_function(info, 64'h0000_0000_0000_0101, 32'd1);
    adapter.cfg_read32(pf_bdf, '{value:12'h000}, data, status);
    if (!status.ok() || data[15:0] != 16'h20f9)
      `uvm_error("CFG_READ", "PF vendor ID read did not use canonical manager")

    adapter.cfg_write32(pf_bdf, '{value:12'h004},
                        32'h0000_0007, 4'hf, status);
    if (!status.ok())
      `uvm_error("CFG_WRITE", "PF command write was rejected")
    status = adapter.get_function_info(pf_bdf, info);
    if (!status.ok() || !info.mse || !info.bme)
      `uvm_error("COMMAND", "MSE/BME state did not follow config write")

    adapter.cfg_read32('{segment:16'h0, bus:8'h7f,
                        device:5'h1f, function_num:3'h7},
                       '{value:12'h000}, data, status);
    if (status.code != RDMA_SC_PCIE_COMPLETION)
      `uvm_error("CFG_UNKNOWN", "unknown BDF was not rejected")
  endtask

  // 功能：检查 VF BAR0 地址到目标 BDF/offset 的唯一解码，随后验证 disabled VF、stale
  //   generation 和正确 Function handle 对 MMIO 写入的不同处理。
  // 输入/输出及副作用：向 adapter 提交一个 4-byte MMIO 写入并读取 decode 结果；成功
  //   路径不修改 manager 之外的外部 PCIe 资源，失败路径不发布部分 route。
  // 失败/边界：跨 VF aperture、disabled VF、空数据和代际不匹配必须 fail-closed；不能
  //   仅凭 address 猜测 Function，也不能让 stale handle 写入 BAR。
  task automatic test_bar_decode_and_mmio();
    rdma_bar_decode decoded;
    rdma_bdf_t vf_bdf;
    rdma_bar_addr_t address;
    rdma_status status;
    byte payload[$];
    rdma_function_handle function_h;
    rdma_function_handle stale_h;

    vf_bdf = to_rdma_bdf(func_mgr.vf_ctx[0][0].bdf);
    address.value = func_mgr.sriov_caps[0].vf_bar[0] + 64'h100;
    status = adapter.decode_bar(address, decoded);
    if (!status.ok() || !rdma_bdf_same(decoded.target_bdf, vf_bdf) ||
        decoded.bar_id != 0 || decoded.bar_offset != 64'h100)
      `uvm_error("BAR_DECODE", "VF BAR route/offset mismatch")

    function_h = rdma_function_handle::type_id::create("function_h");
    function_h.function_uid = 64'h0000_0000_0000_0101;
    function_h.object_id = 32'd1;
    function_h.generation = int'(func_mgr.config_generation);
    payload = '{8'hde, 8'had, 8'hbe, 8'hef};
    adapter.mmio_write(function_h, address, payload, status);
    if (!status.ok())
      `uvm_error("MMIO", "Function-aware VF MMIO write was rejected")
    adapter.dma_visibility_barrier(function_h, status);
    if (!status.ok())
      `uvm_error("DMA_BARRIER", "DMA visibility barrier was rejected")
    adapter.mmio_ordering_barrier(function_h, status);
    if (!status.ok())
      `uvm_error("MMIO_BARRIER", "MMIO ordering barrier was rejected")

    stale_h = rdma_function_handle::type_id::create("stale_h");
    stale_h.copy(function_h);
    stale_h.generation++;
    adapter.mmio_write(stale_h, address, payload, status);
    if (status.code != RDMA_SC_STALE_GENERATION)
      `uvm_error("STALE_MMIO", "stale Function generation was accepted")

    func_mgr.disable_vfs(0);
    status = adapter.decode_bar(address, decoded);
    if (status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("DISABLED_VF", "disabled VF BAR was not rejected")
  endtask

  // 功能：运行 PCIe adapter 的 SR-IOV、配置、BAR decode、MMIO 和恢复边界检查，并在
  //   每个阶段结束时释放 UVM objection。
  // 输入/输出及副作用：phase（输入）；task 创建本地 fixture、执行断言并更新测试报告，
  //   不拥有外部 PCIe/VIP 生命周期；正常完成时 drop_objection。
  // 失败/边界：fixture 或任一阶段失败会产生 UVM error/fatal；不会吞掉后端错误或继续
  //   使用未配置的 adapter。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    build_fixture();
    test_config_and_sriov();
    test_bar_decode_and_mmio();
    phase.drop_objection(this);
  endtask
endclass
